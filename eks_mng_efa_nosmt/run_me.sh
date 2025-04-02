#!/bin/bash

export AWS_PAGER=""

# ENV
CLUSTER_NAME=${CLUSTER_NAME:-"hpc-custom"}
AWS_REGION=${AWS_REGION:-"us-west-2"}
AWS_PROFILE=${AWS_PROFILE:-"coa"}
EKS_AMI_ID=${EKS_AMI_ID:-"ami-019ce8ced84df229a"}
NODEGROUP_NAME=${NODEGROUP_NAME:-"cpu-reserved-nodegroup3"}
DESIRED_CAPACITY=${DESIRED_CAPACITY:-"1"}
MIN_SIZE=${MIN_SIZE:-"1"}
MAX_SIZE=${MAX_SIZE:-"1"}

# Get the AMI family from the AMI ID
AMI_FAMILY=$(aws ec2 describe-images \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --image-ids $EKS_AMI_ID \
  --query 'Images[0].Description' \
  --output text | grep -o 'Amazon Linux 2\|Ubuntu\|Bottlerocket\|Windows' || echo "AmazonLinux2")
case "$AMI_FAMILY" in
  "Amazon Linux 2")
    EKSCTL_AMI_FAMILY="AmazonLinux2"
    ;;
  "Ubuntu")
    EKSCTL_AMI_FAMILY="Ubuntu2004"
    ;;
  "Bottlerocket")
    EKSCTL_AMI_FAMILY="Bottlerocket"
    ;;
  "Windows")
    EKSCTL_AMI_FAMILY="WindowsServer2019FullContainer"
    ;;
  *)
    EKSCTL_AMI_FAMILY="AmazonLinux2"  # Default fallback
    ;;
esac
echo "Detected AMI family: $AMI_FAMILY"
echo "eksctl AMI family: $EKSCTL_AMI_FAMILY"

# VPC ID
VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo "VPC ID: $VPC_ID"

# Get the VPC CIDR block
VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids $VPC_ID \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "Vpcs[0].CidrBlock" \
  --output text)
echo "VPC CIDR: $VPC_CIDR"

# SG ID
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*$CLUSTER_NAME*" \
  --query "SecurityGroups[0].GroupId" \
  --output text)
echo "Security Group ID: $SECURITY_GROUP_ID"

# Get subnet IDs as a JSON array and process one by one
SUBNET_IDS=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "cluster.resourcesVpcConfig.subnetIds" \
  --output json)

# Initialize variables for a and b AZ subnets
PRIVATE_SUBNET_A=""
PRIVATE_SUBNET_B=""

# Process each subnet ID to find private subnets
for SUBNET_ID in $(echo $SUBNET_IDS | jq -r '.[]'); do
  echo "Checking subnet: $SUBNET_ID"
  # Get AZ for the subnet
  AZ=$(aws ec2 describe-subnets \
    --subnet-ids $SUBNET_ID \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "Subnets[0].AvailabilityZone" \
    --output text)
  echo "  Availability Zone: $AZ"
  # Check if subnet is private by looking at route tables
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "RouteTables[0].RouteTableId" \
    --output text)
  if [ -z "$ROUTE_TABLE_ID" ] || [ "$ROUTE_TABLE_ID" == "None" ]; then
    echo "  No route table found for this subnet, checking default VPC route table..."
    # Try to get the main route table for the VPC
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --region $AWS_REGION \
      --profile $AWS_PROFILE \
      --query "RouteTables[0].RouteTableId" \
      --output text 2>/dev/null)
  fi
  if [ -n "$ROUTE_TABLE_ID" ] && [ "$ROUTE_TABLE_ID" != "None" ]; then
    echo "  Route table ID: $ROUTE_TABLE_ID"
    HAS_IGW=$(aws ec2 describe-route-tables \
      --route-table-ids $ROUTE_TABLE_ID \
      --region $AWS_REGION \
      --profile $AWS_PROFILE \
      --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, 'igw-')].GatewayId" \
      --output text 2>/dev/null)
    if [ -z "$HAS_IGW" ]; then
      echo "  This is a private subnet (no IGW route)"
      if [[ $AZ == *"a"* ]]; then
        PRIVATE_SUBNET_A=$SUBNET_ID
        echo "  Assigned as Subnet A (zone a)"
      elif [[ $AZ == *"b"* ]]; then
        PRIVATE_SUBNET_B=$SUBNET_ID
        echo "  Assigned as Subnet B (zone b)"
      fi
    else
      echo "  This is a public subnet (has IGW route)"
    fi
  else
    echo "  Could not determine if subnet is private, assuming it is"
    if [[ $AZ == *"a"* ]] && [ -z "$PRIVATE_SUBNET_A" ]; then
      PRIVATE_SUBNET_A=$SUBNET_ID
      echo "  Assigned as Subnet A (zone a)"
    elif [[ $AZ == *"b"* ]] && [ -z "$PRIVATE_SUBNET_B" ]; then
      PRIVATE_SUBNET_B=$SUBNET_ID
      echo "  Assigned as Subnet B (zone b)"
    fi
  fi
done
if [ -z "$PRIVATE_SUBNET_A" ] || [ -z "$PRIVATE_SUBNET_B" ]; then
  echo "ERROR: Could not find private subnets in both AZs a and b"
  echo "Found subnet A: $PRIVATE_SUBNET_A"
  echo "Found subnet B: $PRIVATE_SUBNET_B"
  echo "Please check your cluster configuration and retry"
  exit 1
fi
echo "Using private subnets:"
echo "  Subnet A (us-west-2a): $PRIVATE_SUBNET_A"
echo "  Subnet B (us-west-2b): $PRIVATE_SUBNET_B"

# Node role name
NODE_ROLE_NAME=$(aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE --query "nodegroups[0]" --output text) \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "nodegroup.nodeRole" \
  --output text 2>/dev/null | awk -F '/' '{print $NF}' || echo "")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile $AWS_PROFILE \
  --query "Account" \
  --output text)
INSTANCE_PROFILE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:instance-profile/$NODE_ROLE_NAME"
NODE_ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$NODE_ROLE_NAME"
echo "Instance Profile ARN: $INSTANCE_PROFILE_ARN"
echo "Instance Profile ARN: $NODE_ROLE_ARN"

# Inline policies
echo "Add worknode policy"
aws iam attach-role-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  --role-name $NODE_ROLE_NAME | jq

echo "Add pull policy"
aws iam attach-role-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly \
  --role-name $NODE_ROLE_NAME | jq

echo "Add EKS read-only policy"
aws iam attach-role-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
  --role-name $NODE_ROLE_NAME | jq

echo "Add ipv4 cni policy"
aws iam attach-role-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  --role-name $NODE_ROLE_NAME | jq

echo "Setup ipv6 policy"
cat >vpc-cni-ipv6-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AssignIpv6Addresses",
                "ec2:DescribeInstances",
                "ec2:DescribeTags",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeInstanceTypes"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags"
            ],
            "Resource": [
                "arn:aws:ec2:*:*:network-interface/*"
            ]
        }
    ]
}
EOF

POLICY_NAME="AmazonEKS_CNI_IPv6_Policy"
POLICY_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:policy/$POLICY_NAME"
# First check if the policy already exists
echo "Checking if policy $POLICY_NAME already exists..."
aws iam get-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn $POLICY_ARN &> /dev/null
POLICY_EXISTS=$?

if [ $POLICY_EXISTS -eq 0 ]; then
  echo "Policy $POLICY_NAME already exists. Skipping creation."
NODEGROUP_NAME=${NODEGROUP_NAME:-"cpu-reserved-nodegroup3"}
else
  echo "Policy does not exist. Creating it..."
  aws iam create-policy \
    --region us-west-2 \
    --profile coa \
    --policy-name $POLICY_NAME \
    --policy-document file://vpc-cni-ipv6-policy.json | jq
fi

# Attach the policy to the role (will proceed whether the policy was just created or already existed)
echo "Adding ipvc policy"
aws iam attach-role-policy \
  --region us-west-2 \
  --profile coa \
  --policy-arn $POLICY_ARN \
  --role-name $NODE_ROLE_NAME | jq

# Enable DNS support in VPC
echo "Enabling DNS support in VPC..."
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-support "{\"Value\":true}" \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames "{\"Value\":true}" \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

# Create VPC endpoints for required AWS services
echo "Creating VPC endpoints for required AWS services..."

# Create security group for VPC endpoints
SG_NAME="eks-endpoint-sg-$CLUSTER_NAME"
ENDPOINT_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null)

if [ -z "$ENDPOINT_SG" ] || [ "$ENDPOINT_SG" == "None" ]; then
  echo "Creating endpoint security group..."
  ENDPOINT_SG=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for EKS VPC endpoints" \
    --vpc-id $VPC_ID \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "GroupId" \
    --output text)

  # Allow inbound HTTPS from VPC CIDR
  aws ec2 authorize-security-group-ingress \
    --group-id $ENDPOINT_SG \
    --protocol tcp \
    --port 443 \
    --cidr $VPC_CIDR \
    --region $AWS_REGION \
    --profile $AWS_PROFILE
else
  echo "Using existing security group: $ENDPOINT_SG"
fi

# Function to create or update VPC endpoint
create_vpc_endpoint() {
  local service=$1
  local endpoint_type=$2
  
  # Check if endpoint exists
  local endpoint_exists=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=service-name,Values=com.amazonaws.$AWS_REGION.$service" "Name=vpc-id,Values=$VPC_ID" \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "VpcEndpoints[0].VpcEndpointId" \
    --output text)
  
  if [ "$endpoint_exists" != "None" ] && [ -n "$endpoint_exists" ]; then
    echo "VPC endpoint for $service already exists: $endpoint_exists"
    
    # For existing interface endpoints, make sure the private DNS is enabled
    if [ "$endpoint_type" == "Interface" ]; then
      aws ec2 modify-vpc-endpoint \
        --vpc-endpoint-id $endpoint_exists \
        --add-subnet-ids $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B \
        --add-security-group-ids $ENDPOINT_SG \
        --region $AWS_REGION \
        --profile $AWS_PROFILE || echo "Could not modify endpoint $service. Continuing..."
    fi
  else
    echo "Creating VPC endpoint for $service..."
    
    if [ "$endpoint_type" == "Gateway" ]; then
      # Gateway endpoint (S3)
      aws ec2 create-vpc-endpoint \
        --vpc-id $VPC_ID \
        --service-name com.amazonaws.$AWS_REGION.$service \
        --vpc-endpoint-type Gateway \
        --route-table-ids $(aws ec2 describe-route-tables \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --region $AWS_REGION \
          --profile $AWS_PROFILE \
          --query "RouteTables[].RouteTableId" \
          --output text) \
        --region $AWS_REGION \
        --profile $AWS_PROFILE
    else
      # Interface endpoint
      aws ec2 create-vpc-endpoint \
        --vpc-id $VPC_ID \
        --service-name com.amazonaws.$AWS_REGION.$service \
        --vpc-endpoint-type Interface \
        --subnet-ids $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B \
        --security-group-ids $ENDPOINT_SG \
        --private-dns-enabled \
        --region $AWS_REGION \
        --profile $AWS_PROFILE || echo "Failed to create endpoint for $service with private DNS. Trying without private DNS..."
      
      # If the first attempt failed, try without private DNS
      if [ $? -ne 0 ]; then
        aws ec2 create-vpc-endpoint \
          --vpc-id $VPC_ID \
          --service-name com.amazonaws.$AWS_REGION.$service \
          --vpc-endpoint-type Interface \
          --subnet-ids $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B \
          --security-group-ids $ENDPOINT_SG \
          --region $AWS_REGION \
          --profile $AWS_PROFILE || echo "Could not create endpoint for $service at all. Continuing..."
      fi
    fi
  fi
}

# Create all necessary endpoints
create_vpc_endpoint "s3" "Gateway"
create_vpc_endpoint "ec2" "Interface"
create_vpc_endpoint "eks" "Interface"
create_vpc_endpoint "ecr.api" "Interface"
create_vpc_endpoint "ecr.dkr" "Interface"
create_vpc_endpoint "logs" "Interface"

# Create Route53 Resolver Endpoint for DNS resolution
echo "Creating Route53 Resolver Endpoint..."
RESOLVER_SG=$(aws ec2 create-security-group \
  --group-name "eks-r53resolver-$CLUSTER_NAME" \
  --description "Security group for Route53 Resolver" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --query "GroupId" \
  --output text 2>/dev/null || echo "")

if [ -n "$RESOLVER_SG" ]; then
  # Allow DNS traffic from VPC
  aws ec2 authorize-security-group-ingress \
    --group-id $RESOLVER_SG \
    --protocol udp \
    --port 53 \
    --cidr $VPC_CIDR \
    --region $AWS_REGION \
    --profile $AWS_PROFILE

  aws ec2 authorize-security-group-ingress \
    --group-id $RESOLVER_SG \
    --protocol tcp \
    --port 53 \
    --cidr $VPC_CIDR \
    --region $AWS_REGION \
    --profile $AWS_PROFILE

  # Create inbound resolver
  aws route53resolver create-resolver-endpoint \
    --name "eks-inbound-resolver-$CLUSTER_NAME" \
    --direction INBOUND \
    --security-group-ids $RESOLVER_SG \
    --ip-addresses \
      SubnetId=$PRIVATE_SUBNET_A,Ip=AUTO_IP \
      SubnetId=$PRIVATE_SUBNET_B,Ip=AUTO_IP \
    --creator-request-id "eks-resolver-$(date +%s)" \
    --region $AWS_REGION \
    --profile $AWS_PROFILE || echo "Could not create Route53 Resolver. Continuing..."
fi

# Wait for endpoints to become available
echo "Waiting for VPC endpoints to initialize..."
sleep 20

# Generate launch template
echo "Creating launch template userdata"
API_SERVER_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE --query "cluster.endpoint" --output text)
B64_CLUSTER_CA=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE --query "cluster.certificateAuthority.data" --output text)
cat > user-data.txt << EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="
--==MYBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"
#!/bin/bash

## Set CNI environment variables
#echo 'export AWS_VPC_K8S_CNI_LOGLEVEL=DEBUG' >> /etc/environment
#echo 'export AWS_VPC_K8S_CNI_LOG_FILE=/var/log/aws-routed-eni/ipamd.log' >> /etc/environment
#echo 'export AWS_VPC_K8S_PLUGIN_LOG_LEVEL=DEBUG' >> /etc/environment
#echo 'export AWS_VPC_K8S_PLUGIN_LOG_FILE=/var/log/aws-routed-eni/plugin.log' >> /etc/environment
#echo 'export ADDITIONAL_ENI_TAGS={}' >> /etc/environment
#echo 'export AWS_VPC_K8S_CNI_EXTERNALSNAT=false' >> /etc/environment
#echo 'export AWS_VPC_K8S_CNI_VETHPREFIX=eni' >> /etc/environment
#echo 'export AWS_VPC_ENI_MTU=9001' >> /etc/environment
#echo 'export AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=$VPC_CIDR' >> /etc/environment
#
## Create CNI directories early
#mkdir -p /etc/cni/net.d
#mkdir -p /opt/cni/bin
#mkdir -p /var/log/aws-routed-eni
#
## Create CNI configuration file
#cat > /etc/cni/net.d/10-aws.conflist << 'CNIEOF'
#{
#  "cniVersion": "0.4.0",
#  "name": "aws-cni",
#  "plugins": [
#    {
#      "name": "aws-cni",
#      "type": "aws-cni",
#      "vethPrefix": "eni",
#      "mtu": "9001",
#      "pluginLogFile": "/var/log/aws-routed-eni/plugin.log",
#      "pluginLogLevel": "DEBUG"
#    },
#    {
#      "type": "portmap",
#      "capabilities": {"portMappings": true},
#      "snat": true
#    }
#  ]
#}
#CNIEOF
#
## Make sure necessary kernel modules are loaded
#modprobe overlay
#modprobe br_netfilter
#
## Set kernel parameters required for Kubernetes networking
#cat > /etc/sysctl.d/99-kubernetes.conf << 'SYSCTLEOF'
#net.bridge.bridge-nf-call-iptables = 1
#net.bridge.bridge-nf-call-ip6tables = 1
#net.ipv4.ip_forward = 1
#SYSCTLEOF
#sysctl --system
#
## Install troubleshooting tools
#yum install -y tcpdump bind-utils nc
#
## Fix potential SELinux issues
#if [ -f /etc/selinux/config ]; then
#  setenforce 0
#  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
#fi
#
## Fix permissions on CNI directories
#chmod 755 /etc/cni/net.d
#chmod 755 /opt/cni/bin
#
## Fix DNS resolution for EC2 endpoint
#echo '127.0.0.1 localhost' > /etc/hosts
#hostname -I | awk '{print \$1 " $(hostname)"}' >> /etc/hosts
#
## Add EC2 endpoint to hosts file
#EC2_IP=\$(getent hosts ec2.us-west-2.amazonaws.com | awk '{print \$1}')
#if [ -z "\$EC2_IP" ]; then
#  echo "# Using VPC endpoint for EC2" >> /etc/hosts
#  echo "${VPC_CIDR%.*}.2 ec2.us-west-2.amazonaws.com" >> /etc/hosts
#fi
#
## Configure DNS resolvers to use Amazon DNS
#cat > /etc/resolv.conf << 'RESOLVCONF'
#nameserver 169.254.169.253
#options timeout:2 attempts:5
#RESOLVCONF
#
## Add AWS metadata endpoint
#echo "169.254.169.254 metadata.eth0.ec2.internal" >> /etc/hosts
#
## Test DNS resolution before bootstrap
#echo "Testing DNS resolution before bootstrap..."
#nslookup ec2.us-west-2.amazonaws.com
#nslookup eks.us-west-2.amazonaws.com
#
## Pre-pull container images to speed up pod startup
#echo "Pre-pulling critical container images..."
#crictl pull public.ecr.aws/eks-distro/kubernetes/pause:3.5
#
## Set correct file permissions for AWS CNI plugin
#mkdir -p /var/run/aws-node
#chmod 755 /var/run/aws-node
#
## Static cluster information
CLUSTER_NAME="$CLUSTER_NAME"
API_SERVER_URL="$API_SERVER_URL"
B64_CLUSTER_CA="$B64_CLUSTER_CA"

# Bootstrap the node with the provided information
/etc/eks/bootstrap.sh \$CLUSTER_NAME \\
  --b64-cluster-ca \$B64_CLUSTER_CA \\
  --apiserver-endpoint \$API_SERVER_URL \\
  --kubelet-extra-args '--cpu-manager-policy=static --feature-gates=CPUManagerPolicyOptions=true,CPUManagerPolicyAlphaOptions=true --cpu-manager-policy-options=strict-cpu-reservation=true --reserved-cpus=0,1,2,3 --kube-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi --system-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi'
#"--feature-gates=CPUManagerPolicyAlphaOptions=true \\
#  --cpu-manager-policy=static \\
#  --kube-reserved=cpu=1,memory=2Gi,ephemeral-storage=1Gi \\
#  --system-reserved=cpu=1,memory=2Gi,ephemeral-storage=1Gi \\
#  --eviction-hard=memory.available<200Mi,nodefs.available<10% \\
#  --feature-gates=CPUManager=true \\
#  --cpu-manager-reconcile-period=5s \\
#  --topology-manager-policy=single-numa-node \\
#  --reserved-cpus=0,1 \\
#  --cpu-manager-policy-options=strict-cpu-reservation=true"

# Restart kubelet to apply changes
systemctl restart kubelet
--==MYBOUNDARY==--
EOF
USER_DATA=$(base64 -w 0 user-data.txt)

echo "Checking if launch template $TEMPLATE_NAME exists..."
TEMPLATE_NAME="eks-cpu-nosmt-bootstrap"
echo "Checking if launch template $TEMPLATE_NAME exists..."
TEMPLATE_EXISTS_OUTPUT=$(aws ec2 describe-launch-templates \
  --launch-template-names $TEMPLATE_NAME \
  --profile coa \
  --region us-west-2 2>/dev/null)

# Generate a launch template
if [ $? -eq 0 ]; then
  echo "Launch template $TEMPLATE_NAME already exists. Creating a new version..."
  TEMPLATE_ID=$(echo "$TEMPLATE_EXISTS_OUTPUT" | jq -r '.LaunchTemplates[0].LaunchTemplateId')
  # Create a new version of the existing template
  VERSION_OUTPUT=$(aws ec2 create-launch-template-version \
    --launch-template-name $TEMPLATE_NAME \
    --profile coa \
    --region us-west-2 \
    --version-description "Static CPU policy with disabled SMT" \
    --launch-template-data "{
      \"InstanceType\": \"c5n.9xlarge\",
      \"ImageId\": \"$EKS_AMI_ID\",
      \"CpuOptions\": {
        \"CoreCount\": 18,
        \"ThreadsPerCore\": 1
      },
      \"BlockDeviceMappings\": [
        {
          \"DeviceName\": \"/dev/xvda\",
          \"Ebs\": {
            \"VolumeSize\": 400,
            \"VolumeType\": \"gp3\",
            \"DeleteOnTermination\": true
          }
        }
      ],
      \"NetworkInterfaces\": [
        {
          \"DeviceIndex\": 0,
          \"DeleteOnTermination\": true
        },
        {
          \"DeviceIndex\": 1,
          \"InterfaceType\": \"efa-only\",
          \"DeleteOnTermination\": true
        }
      ],
      \"UserData\": \"$USER_DATA\"
    }")
  VERSION_NUMBER=$(echo "$VERSION_OUTPUT" | jq -r '.LaunchTemplateVersion.VersionNumber')
else
  echo "Launch template does not exist. Creating it..."
  TEMPLATE_OUTPUT=$(aws ec2 create-launch-template \
    --launch-template-name $TEMPLATE_NAME \
    --profile coa \
    --region us-west-2 \
    --version-description "Static CPU policy with disabled SMT" \
    --launch-template-data "{
      \"InstanceType\": \"c5n.9xlarge\",
      \"ImageId\": \"$EKS_AMI_ID\",
      \"IamInstanceProfile\": {
        \"Arn\": \"$INSTANCE_PROFILE_ARN\"
      },
      \"CpuOptions\": {
        \"CoreCount\": 18,
        \"ThreadsPerCore\": 1
      },
      \"BlockDeviceMappings\": [
        {
          \"DeviceName\": \"/dev/xvda\",
          \"Ebs\": {
            \"VolumeSize\": 400,
            \"VolumeType\": \"gp3\",
            \"DeleteOnTermination\": true
          }
        }
      ],
      \"UserData\": \"$USER_DATA\"
    }")
  # Get the template ID and version number
  TEMPLATE_ID=$(echo "$TEMPLATE_OUTPUT" | jq -r '.LaunchTemplate.LaunchTemplateId')
  VERSION_NUMBER=$(echo "$TEMPLATE_OUTPUT" | jq -r '.LaunchTemplate.VersionNumber')
fi
echo "Launch Template ID: $TEMPLATE_ID"
echo "Launch Template Version: $VERSION_NUMBER"

# Generate the nodegroup config file
CONFIG_FILE="nodegroup-${NODEGROUP_NAME}.yaml"
cat > ${CONFIG_FILE} << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
iam:
  withOIDC: true
availabilityZones: ["us-west-2a", "us-west-2b"]
vpc:
  id: ${VPC_ID}
  subnets:
    private:
      us-west-2a: { id: ${PRIVATE_SUBNET_A} }
      us-west-2b: { id: ${PRIVATE_SUBNET_B} }
  securityGroup: ${SECURITY_GROUP_ID}
managedNodeGroups:
  - name: ${NODEGROUP_NAME}
    iam:
      instanceRoleARN: ${NODE_ROLE_ARN}
    desiredCapacity: ${DESIRED_CAPACITY}
    minSize: ${MIN_SIZE}
    maxSize: ${MAX_SIZE}
    labels:
      cpu-manager: "enabled"
      nodegroup-type: "${NODEGROUP_NAME}"
    tags:
      nodegroup-type: "${NODEGROUP_NAME}"
    privateNetworking: true
    efaEnabled: true
    availabilityZones: ["us-west-2a"]
#    subnets:
#      - ${PRIVATE_SUBNET_A}
#      - ${PRIVATE_SUBNET_B}
    launchTemplate:
      id: ${TEMPLATE_ID}
      version: "${VERSION_NUMBER}"
EOF

echo "Generated nodegroup config: ${CONFIG_FILE}"
echo "Attempting to create nodegroup:"
eksctl create nodegroup --config-file="${CONFIG_FILE}" --profile="${AWS_PROFILE}" --timeout=5m0s
