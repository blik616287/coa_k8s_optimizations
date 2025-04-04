export AWS_PAGER=""

VPC_ID="vpc-07b388829583e6dc7"
AWS_REGION=${AWS_REGION:-"us-west-2"}
AWS_PROFILE=${AWS_PROFILE:-"coa"}
PRIVATE_SUBNET_A="subnet-0bdd69129d90bf460"
PRIVATE_SUBNET_B="subnet-0bb4f4ad200d15838"
EKS_VERSION=${EKS_VERSION:-"1.32"}
CLUSTER_NAME=${CLUSTER_NAME:-"mforde-hpc"}
NODENAME_GROUP=${NODENAME_GROUP:-"my-efa-ng27"}
INSTANCE_TYPE=${INSTANCE_TYPE:="c5n.9xlarge"}

# Instance metadata
INSTANCE_INFO=$(aws ec2 describe-instance-types \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE} \
  --instance-types ${INSTANCE_TYPE} \
  --query "InstanceTypes[0].{vCPUs:VCpuInfo.DefaultVCpus, PhysicalProcessor:ProcessorInfo.SupportedArchitectures[0], CoreCount:VCpuInfo.DefaultCores}" \
  --output json)
CORE_COUNT=$(echo $INSTANCE_INFO | jq -r '.CoreCount')
echo "CORE_COUNT: ${CORE_COUNT}"

# Controlplane SG
aws ec2 create-security-group \
  --group-name eksctl-${CLUSTER_NAME}-cluster-ControlPlaneSecurityGroup \
  --description "Communication between the control plane and worker nodegroups" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --profile $AWS_PROFILE \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=eksctl-${CLUSTER_NAME}-cluster/ControlPlaneSecurityGroup}]"
CONTROL_PLANE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/ControlPlaneSecurityGroup" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE)
echo "CONTROL_PLANE_SG: ${CONTROL_PLANE_SG}"

# SharedNode SG
aws ec2 create-security-group \
  --group-name eksctl-${CLUSTER_NAME}-cluster-ClusterSharedNodeSecurityGroup \
  --description "Communication between all nodes in the cluster" \
  --vpc-id $VPC_ID \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE} \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=eksctl-${CLUSTER_NAME}-cluster/ClusterSharedNodeSecurityGroup}]"
aws ec2 authorize-security-group-ingress \
  --group-id $SHARED_NODE_SG \
  --ip-permissions 'IpProtocol=-1,UserIdGroupPairs=[{GroupId='$SHARED_NODE_SG',Description="Allow nodes to communicate with each other (all ports)"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 authorize-security-group-ingress \
  --group-id $SHARED_NODE_SG \
  --ip-permissions 'IpProtocol=-1,FromPort=0,ToPort=65535,UserIdGroupPairs=[{GroupId='$CLUSTER_SG_ID',Description="Allow managed and unmanaged nodes to communicate with each other (all ports)"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
SHARED_NODE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/ClusterSharedNodeSecurityGroup" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE})
echo "SHARED_NODE_SG: ${SHARED_NODE_SG}"

# Cluster service role
aws iam create-role \
  --role-name eksctl-${CLUSTER_NAME}-cluster-ServiceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "eks.amazonaws.com"
        },
        "Action": ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  }' \
  --profile ${AWS_PROFILE}
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-cluster-ServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
  --profile ${AWS_PROFILE}
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-cluster-ServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSVPCResourceController \
  --profile ${AWS_PROFILE}
aws iam tag-role \
  --role-name eksctl-${CLUSTER_NAME}-cluster-ServiceRole \
  --tags "[{\"Key\":\"Name\",\"Value\":\"eksctl-${CLUSTER_NAME}-cluster/ServiceRole\"}]" \
  --profile ${AWS_PROFILE}
SERVICE_ROLE_ARN=$(aws iam get-role \
  --role-name eksctl-${CLUSTER_NAME}-cluster-ServiceRole \
  --query "Role.Arn" \
  --output text \
  --profile ${AWS_PROFILE})
echo "SERVICE_ROLE_ARN: ${SERVICE_ROLE_ARN}"

# Create cluster
aws eks create-cluster \
  --kubernetes-version ${EKS_VERSION} \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE} \
  --name ${CLUSTER_NAME} \
  --role-arn $SERVICE_ROLE_ARN \
  --resources-vpc-config subnetIds=$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B,securityGroupIds=$CONTROL_PLANE_SG,endpointPublicAccess=true,endpointPrivateAccess=true \
  --access-config authenticationMode=API_AND_CONFIG_MAP,bootstrapClusterCreatorAdminPermissions=true \
  --no-bootstrap-self-managed-addons \
  --tags Key=Name,Value=eksctl-${CLUSTER_NAME}-cluster/ControlPlane
aws eks wait cluster-active \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}

# Cluster SG
CLUSTER_SG_ID=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE})
aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG_ID \
  --ip-permissions 'IpProtocol=-1,FromPort=0,ToPort=65535,UserIdGroupPairs=[{GroupId='$SHARED_NODE_SG',Description="Allow unmanaged nodes to communicate with control plane (all ports)"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
echo "CLUSTER_SG_ID: $CLUSTER_SG_ID"
  
# OIDC provider
OIDC_PROVIDER_URL=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query "cluster.identity.oidc.issuer" \
  --output text \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE})
OIDC_ID=$(echo $OIDC_PROVIDER_URL | cut -d'/' -f5)
OIDC_PROVIDER_EXISTS=$(aws iam list-open-id-connect-providers \
  --query "length(OpenIDConnectProviderList[?contains(Arn, '${OIDC_ID}')])" \
  --output text \
  --profile ${AWS_PROFILE})
if [ "$OIDC_PROVIDER_EXISTS" -eq "0" ]; then
  echo "Creating OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url $OIDC_PROVIDER_URL \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" \
    --profile ${AWS_PROFILE}
fi
echo "OIDC_ID: $OIDC_ID"

# IAM role for VPC CNI
cat > vpc-cni-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::376129860391:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com",
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-node"
        }
      }
    }
  ]
}
EOF
aws iam create-role \
  --role-name eksctl-${CLUSTER_NAME}-addon-vpc-cni-Role1 \
  --assume-role-policy-document file://vpc-cni-trust-policy.json \
  --profile ${AWS_PROFILE}
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-addon-vpc-cni-Role1 \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  --profile ${AWS_PROFILE}
ROLE_ARN=$(aws iam get-role \
  --role-name eksctl-${CLUSTER_NAME}-addon-vpc-cni-Role1 \
  --query "Role.Arn" \
  --output text \
  --profile ${AWS_PROFILE})
echo "ROLE_ARN: $ROLE_ARN"

# Cluster plugin addons
echo "Adding cluster addons: kube-proxy, coredns, vpc-cni, eks/aws-efa-k8s-device-plugin"
aws eks create-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name kube-proxy \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws eks create-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name coredns \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws eks create-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name vpc-cni \
  --service-account-role-arn ${ROLE_ARN} \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
helm repo add eks https://aws.github.io/eks-charts
helm install aws-efa-k8s-device-plugin --namespace kube-system eks/aws-efa-k8s-device-plugin

# IAM Role for the Node Group
aws iam create-role \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }' \
  --path "/" \
  --profile ${AWS_PROFILE}
NODE_ROLE_ARN=$(aws iam get-role \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --query "Role.Arn" \
  --output text \
  --profile ${AWS_PROFILE})
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  --profile ${AWS_PROFILE}
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  --profile ${AWS_PROFILE}
aws iam attach-role-policy \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --profile ${AWS_PROFILE}
aws iam tag-role \
  --role-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeInstanceRole \
  --tags "[{\"Key\":\"Name\",\"Value\":\"eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng/NodeInstanceRole\"}]" \
  --profile ${AWS_PROFILE}
echo "NODE_ROLE_ARN: ${NODE_ROLE_ARN}"

# EC2 Placement Group
PLACEMENT_GROUP_NAME="eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-NodeGroupPlacementGroup"
aws ec2 create-placement-group \
  --group-name ${PLACEMENT_GROUP_NAME} \
  --strategy cluster \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
echo "PLACEMENT_GROUP_NAME: ${PLACEMENT_GROUP_NAME}"

# EFA Security Group
aws ec2 create-security-group \
  --group-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng-EFASG \
  --description "EFA-enabled security group" \
  --vpc-id ${VPC_ID} \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=kubernetes.io/cluster/'${CLUSTER_NAME}',Value=owned},{Key=Name,Value=eksctl-'${CLUSTER_NAME}'-nodegroup-my-efa-ng/EFASG}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
EFA_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng/EFASG" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE})
aws ec2 authorize-security-group-ingress \
  --group-id $EFA_SG_ID \
  --ip-permissions 'IpProtocol=-1,UserIdGroupPairs=[{GroupId='$EFA_SG_ID',Description="Allow worker nodes in group my-efa-ng to communicate to itself (EFA-enabled)"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 authorize-security-group-egress \
  --group-id $EFA_SG_ID \
  --ip-permissions 'IpProtocol=-1,UserIdGroupPairs=[{GroupId='$EFA_SG_ID',Description="Allow worker nodes in group my-efa-ng to communicate to itself (EFA-enabled)"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
echo "EFA_SG_ID: ${EFA_SG_ID}"
  
# Generate VPC Endpoints
aws ec2 create-security-group \
  --group-name "eks-endpoint-sg-hpc-custom" \
  --description "Security group for EKS VPC endpoints" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
VPCE_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=eks-endpoint-sg-hpc-custom" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE")
aws ec2 authorize-security-group-ingress \
  --group-id $VPCE_SG_ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId='$CONTROL_PLANE_SG',Description="Allow HTTPS from EKS control plane"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 authorize-security-group-ingress \
  --group-id $VPCE_SG_ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId='$CLUSTER_SG_ID',Description="Allow HTTPS from EKS cluster"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 authorize-security-group-ingress \
  --group-id $VPCE_SG_ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId='$EFA_SG_ID',Description="Allow HTTPS from EFA security group"}]' \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.ec2" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-ec2-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.ecr.api" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-ecr-api-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.ecr.dkr" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-ecr-dkr-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.s3" \
  --vpc-endpoint-type Gateway \
  --route-table-ids $(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[*].RouteTableId" \
    --output text \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE") \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-s3-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.eks" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-eks-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.sts" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-sts-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.logs" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-logs-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.ssm" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-ssm-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.$AWS_REGION.ssmmessages" \
  --vpc-endpoint-type Interface \
  --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$CLUSTER_NAME-ssmmessages-endpoint},{Key=Cluster,Value=$CLUSTER_NAME}]" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"
  
# User-Data
API_SERVER_URL=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --profile ${AWS_PROFILE} --query "cluster.endpoint" --output text)
B64_CLUSTER_CA=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --profile ${AWS_PROFILE} --query "cluster.certificateAuthority.data" --output text)
cat > user-data.txt << 'USERDATA_EOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
echo "root:password" | chpasswd

--//
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: CLUSTER_NAME_PLACEHOLDER
    apiServerEndpoint: API_SERVER_URL_PLACEHOLDER
    certificateAuthority: B64_CLUSTER_CA_PLACEHOLDER
    cidr: 172.20.0.0/16
  kubelet:
    flags:
    - "--node-labels=alpha.eksctl.io/cluster-name=mforde-hpc,alpha.eksctl.io/nodegroup-name=NODENAME_GROUP_PLACEHOLDER,eks.amazonaws.com/nodegroup-image=al2023,eks.amazonaws.com/capacityType=ON_DEMAND"
    - "--cpu-manager-policy=static"
    - "--feature-gates=CPUManagerPolicyOptions=true,CPUManagerPolicyAlphaOptions=true"
    - "--cpu-manager-policy-options=strict-cpu-reservation=true"
    - "--reserved-cpus=0,1"
    - "--kube-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi"
    - "--system-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi"
    - "--kube-reserved-cgroup="
    - "--system-reserved-cgroup="

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
yum install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /usr/local/sbin/set_irq_affinity.sh << 'EOF'
#!/bin/bash
CPU_MASK=3
for IRQ_DIR in /proc/irq/[0-9]*; do
  IRQ=$(basename "$IRQ_DIR")
  if [ "$IRQ" -eq 0 ] || [ "$IRQ" -eq 2 ]; then
    continue
  fi
  echo "Setting IRQ $IRQ to CPU mask $CPU_MASK"
  echo "$CPU_MASK" > "$IRQ_DIR/smp_affinity"
done
for EFA_IRQ in $(grep -l efa /proc/irq/*/*/name | awk -F/ '{print $3}'); do
  echo "Setting EFA IRQ $EFA_IRQ to CPU mask $CPU_MASK"
  echo "$CPU_MASK" > "/proc/irq/$EFA_IRQ/smp_affinity"
done
EOF
chmod +x /usr/local/sbin/set_irq_affinity.sh
cat > /etc/systemd/system/irq-affinity.service << EOF
[Unit]
Description=Set IRQ Affinity for HPC Workloads
After=network.target efa.service
Wants=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set_irq_affinity.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable irq-affinity.service
systemctl start irq-affinity.service

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/01-cpu-affinity.conf << EOF
[Manager]
CPUAffinity=0 1
EOF
systemctl daemon-reload

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /etc/sysctl.d/90-efa-hpc.conf << EOF
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
net.core.netdev_max_backlog = 8192
net.core.busy_poll = 1
net.core.busy_read = 50
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_sack = 0
kernel.numa_balancing = 0
kernel.randomize_va_space = 0
vm.nr_hugepages = 20000
EOF
sysctl -p /etc/sysctl.d/90-efa-hpc.conf

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /etc/systemd/system/disable-transparent-hugepage.service << EOF
[Unit]
Description=Disable transparent hugepage
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable disable-transparent-hugepage.service
systemctl start disable-transparent-hugepage.service

--//--
USERDATA_EOF
sed -i "s|CLUSTER_NAME_PLACEHOLDER|${CLUSTER_NAME}|g" user-data.txt
sed -i "s|API_SERVER_URL_PLACEHOLDER|${API_SERVER_URL}|g" user-data.txt
sed -i "s|B64_CLUSTER_CA_PLACEHOLDER|${B64_CLUSTER_CA}|g" user-data.txt
sed -i "s|NODENAME_GROUP_PLACEHOLDER|${NODENAME_GROUP}|g" user-data.txt
ENCODED_USER_DATA=$(base64 -w 0 user-data.txt)
echo "ENCODED_USER_DATA has been set."
echo "Length of encoded data: $(echo "$ENCODED_USER_DATA" | wc -c) characters"

# Launch template
cat > launch-template-data.json << EOF
{
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "Groups": ["${CLUSTER_SG_ID}", "${EFA_SG_ID}"],
      "InterfaceType": "efa",
      "NetworkCardIndex": 0
    }
  ],
  "CpuOptions": {
    "CoreCount": ${CORE_COUNT},
    "ThreadsPerCore": 1
  },
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": {
        "VolumeSize": 400,
        "VolumeType": "gp3",
        "Iops": 3000,
        "Throughput": 125
      }
    }
  ],
  "MetadataOptions": {
    "HttpPutResponseHopLimit": 2,
    "HttpEndpoint": "enabled",
    "HttpTokens": "required"
  },
  "Placement": {
    "GroupName": "${PLACEMENT_GROUP_NAME}"
  },
  "UserData": "${ENCODED_USER_DATA}",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {
          "Key": "Name",
          "Value": "${CLUSTER_NAME}-my-efa-ng-Node"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-name",
          "Value": "${NODENAME_GROUP}"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-type",
          "Value": "managed"
        }
      ]
    },
    {
      "ResourceType": "volume",
      "Tags": [
        {
          "Key": "Name",
          "Value": "${CLUSTER_NAME}-my-efa-ng-Node"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-name",
          "Value": "${NODENAME_GROUP}"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-type",
          "Value": "managed"
        }
      ]
    },
    {
      "ResourceType": "network-interface",
      "Tags": [
        {
          "Key": "Name",
          "Value": "${CLUSTER_NAME}-my-efa-ng-Node"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-name",
          "Value": "${NODENAME_GROUP}"
        },
        {
          "Key": "alpha.eksctl.io/nodegroup-type",
          "Value": "managed"
        }
      ]
    }
  ]
}
EOF
aws ec2 delete-launch-template \
  --launch-template-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
aws ec2 create-launch-template \
  --launch-template-name eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng \
  --version-description "Initial version" \
  --launch-template-data file://launch-template-data.json \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}
LAUNCH_TEMPLATE_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names eksctl-${CLUSTER_NAME}-nodegroup-my-efa-ng \
  --query "LaunchTemplates[0].LaunchTemplateId" \
  --output text \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE})
echo "LAUNCH_TEMPLATE_ID: ${LAUNCH_TEMPLATE_ID}"

# Create EKS Managed Node Group
aws eks create-nodegroup \
  --cluster-name ${CLUSTER_NAME} \
  --nodegroup-name ${NODENAME_GROUP} \
  --node-role ${NODE_ROLE_ARN} \
  --subnets ${PRIVATE_SUBNET_A} \
  --instance-types ${INSTANCE_TYPE} \
  --ami-type AL2023_x86_64_STANDARD \
  --launch-template id=$LAUNCH_TEMPLATE_ID \
  --scaling-config minSize=1,maxSize=1,desiredSize=1 \
  --labels "alpha.eksctl.io/cluster-name=${CLUSTER_NAME},alpha.eksctl.io/nodegroup-name=${NODENAME_GROUP}" \
  --tags "alpha.eksctl.io/nodegroup-name=${NODENAME_GROUP},alpha.eksctl.io/nodegroup-type=managed" \
  --region ${AWS_REGION} \
  --profile ${AWS_PROFILE}

