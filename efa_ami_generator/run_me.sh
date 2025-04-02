#!/bin/bash

export AWS_PAGER=""

# Variables
PROFILE="coa"
REGION="us-west-2"
CLUSTER_NAME="hpc-custom"
INSTANCE_TYPE="c5n.9xlarge"

# helper: countdown function
countdown() {
    local seconds="$1"
    while [ $seconds -gt 0 ]; do
        echo "$seconds seconds remaining..."
        sleep 1
        : $((seconds--))
    done
}

# helper: booter
update_and_reboot_instance() {
    # Check if required arguments are provided
    if [ $# -ne 2 ]; then
        echo "Usage: update_and_reboot_instance <KEY_FILE> <INSTANCE_IP>"
        return 1
    fi

    local KEY_FILE="$1"
    local INSTANCE_IP="$2"

    # Validate input files and parameters
    if [ ! -f "$KEY_FILE" ]; then
        echo "Error: Key file '$KEY_FILE' does not exist."
        return 1
    fi

    if [[ ! "$INSTANCE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid IP address format."
        return 1
    fi

    # Update and reboot the instance
    echo "Updating and rebooting the instance..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "sudo yum update -y && sudo reboot"

    # Countdown before checking instance availability
    echo "Waiting for instance to reboot (30 seconds)..."
    countdown 30

    # Wait for the instance to be back online
    local max_attempts=10
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "echo 'Instance is back online'" 2>/dev/null; then
            echo "Instance is back and responding"
            return 0
        else
            echo "Waiting for instance to become available... (Attempt $((attempt+1))/$max_attempts)"
            sleep 30
            ((attempt++))
        fi
    done

    echo "Error: Could not reconnect to the instance after multiple attempts."
    return 1
}

# EKS version
EKS_VERSION=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --profile $PROFILE \
  --query "cluster.version" \
  --output text)
echo "EKS Version: $EKS_VERSION"

# EKS optimized base image
BASE_AMI=$(aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/$EKS_VERSION/amazon-linux-2/recommended/image_id \
  --region $REGION \
  --profile $PROFILE \
  --query "Parameter.Value" \
  --output text)
echo "EKS AMI ID: $BASE_AMI"

# VPC of cluster
VPC=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --profile $PROFILE \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo "VPC ID: $VPC"

# Create key pair
KEY_NAME="efa-key-$(date +%Y%m%d-%H%M%S)"
KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --query 'KeyMaterial' \
    --output text \
    --profile $PROFILE \
    --region $REGION > $KEY_FILE
chmod 400 $KEY_FILE
echo "Key pair created and saved to $KEY_FILE"

# Create IAM role and instance profile for SSM
IAM_ROLE_NAME="EFAInstanceSSMRole-$(date +%Y%m%d-%H%M%S)"
echo "Creating IAM role for SSM access..."
cat > ssm-trust-policy.json << EOF
{
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
}
EOF
aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document file://ssm-trust-policy.json \
    --profile "$PROFILE"
aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    --profile "$PROFILE"
aws iam create-instance-profile \
    --instance-profile-name "$IAM_ROLE_NAME" \
    --profile "$PROFILE"
aws iam add-role-to-instance-profile \
    --role-name "$IAM_ROLE_NAME" \
    --instance-profile-name "$IAM_ROLE_NAME" \
    --profile "$PROFILE"
echo "Waiting for instance profile to be available..."
countdown 10
echo "IAM role and instance profile created: $IAM_ROLE_NAME"

# Get public subnet
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'Subnets[*].SubnetId' \
    --output json \
    --profile $PROFILE \
    --region $REGION)
PUBLIC_SUBNET=""
for SUBNET_ID in $(echo $SUBNETS | jq -r '.[]'); do
    echo "Checking subnet $SUBNET_ID..."
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --profile $PROFILE \
        --region $REGION)
    if [ "$ROUTE_TABLE_ID" = "None" ] || [ -z "$ROUTE_TABLE_ID" ]; then
        ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' \
            --output text \
            --profile $PROFILE \
            --region $REGION)
    fi
    echo "Route table for subnet $SUBNET_ID is $ROUTE_TABLE_ID"
    HAS_IGW=$(aws ec2 describe-route-tables \
        --route-table-ids $ROUTE_TABLE_ID \
        --query 'RouteTables[0].Routes[?GatewayId!=null && contains(GatewayId, `igw-`)]' \
        --output text \
        --profile $PROFILE \
        --region $REGION)
    if [ -n "$HAS_IGW" ]; then
        echo "Subnet $SUBNET_ID is a public subnet (has route to Internet Gateway)"
        PUBLIC_SUBNET=$SUBNET_ID
        break
    else
        echo "Subnet $SUBNET_ID is not a public subnet"
    fi
done
if [ -z "$PUBLIC_SUBNET" ]; then
    echo "No public subnet found, using provided subnet: $SUBNET"
    PUBLIC_SUBNET=$SUBNET
else
    echo "Using public subnet: $PUBLIC_SUBNET"
fi

# Check if security group already exists
SECURITY_GROUP_NAME="efa-enabled-sg"
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC" \
    --profile $PROFILE \
    --region $REGION \
    --query 'SecurityGroups[0].GroupId' \
    --output text)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    echo "Creating new security group: $SECURITY_GROUP_NAME"
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "Security group for EFA-enabled instances" \
        --vpc-id $VPC \
        --profile $PROFILE \
        --region $REGION \
        --output text \
        --query 'GroupId')
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol all \
        --source-group $SG_ID \
        --profile $PROFILE \
        --region $REGION
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --profile $PROFILE \
        --region $REGION
    echo "Created and configured new security group: $SG_ID"
else
    echo "Using existing security group: $SG_ID"
fi
if [ -z "$SG_ID" ]; then
    echo "Error: Failed to get or create security group"
    exit 1
fi

# Launch a temporary instance in the public subnet
echo "Launching temporary instance in a public subnet..."
INSTANCE_NAME="temp-efa-instance-$(date +%Y%m%d-%H%M%S)"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $BASE_AMI \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --iam-instance-profile Name=$IAM_ROLE_NAME \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --network-interfaces "DeviceIndex=0,InterfaceType=efa,Groups=${SG_ID},SubnetId=${PUBLIC_SUBNET},AssociatePublicIpAddress=true" \
    --profile $PROFILE \
    --region $REGION \
    --output text \
    --query 'Instances[0].InstanceId')
echo "Waiting for instance to be in running state..."
aws ec2 wait instance-running \
    --instance-ids $INSTANCE_ID \
    --profile $PROFILE \
    --region $REGION
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --profile $PROFILE \
    --region $REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
echo "Instance $INSTANCE_ID is now running with public IP: $INSTANCE_IP"
echo "Waiting 5 min for instance to be fully initialized..."
countdown 300

# Create ssm efa script to run on the instance
cat > efa_setup.sh << 'EOF'
#!/bin/bash

echo "Starting SSM / EFA setup..."

# Install SSM Agent
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl start amazon-ssm-agent

# Install EFA software
cd $HOME
curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
tar -xf aws-efa-installer-latest.tar.gz
cd aws-efa-installer
sudo ./efa_installer.sh -y

# Setup paths
echo 'export PATH=$PATH:/opt/amazon/openmpi5/bin:/opt/amazon/efa/bin' >> $HOME/.bashrc
echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/amazon/openmpi5/lib' >> $HOME/.bashrc
source $HOME/.bashrc

# Disable ptrace protection
sudo sysctl -w kernel.yama.ptrace_scope=0
echo 'kernel.yama.ptrace_scope = 0' | sudo tee -a /etc/sysctl.d/10-ptrace.conf

# Confirm efa installation
fi_info -p efa -t FI_EP_RDM

# Clean up installation files to reduce AMI size
cd $HOME
rm -rf aws-efa-installer-latest.tar.gz
rm -rf aws-efa-installer

echo "EFA setup completed successfully!"
EOF

# Create a profile.d script to set environment for all shells
cat > mpi_efa_env.sh << 'EOF'

# OpenMPI and EFA binary paths
export PATH=$PATH:/opt/amazon/openmpi5/bin:/opt/amazon/efa/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/amazon/openmpi5/lib:/opt/amazon/efa/lib64

# Modules initialization if not already present
if [ -f /usr/share/Modules/init/bash ]; then
    source /usr/share/Modules/init/bash
fi

# Load OpenMPI module
MODULEPATH=/opt/amazon/modules/modulefiles:/usr/share/Modules/modulefiles:/etc/modulefiles
MODULESHOME=/usr/share/Modules
if command -v module &> /dev/null; then
    module load openmpi5
fi
EOF

# Update user's .bashrc for local user settings
cat > bashrc << 'EOF'

# MPI and EFA environment configuration
export PATH=$PATH:/opt/amazon/openmpi5/bin:/opt/amazon/efa/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/amazon/openmpi5/lib:/opt/amazon/efa/lib64

# Optional: Modules initialization
if [ -f /usr/share/Modules/init/bash ]; then
    source /usr/share/Modules/init/bash
fi

# Load OpenMPI module
MODULEPATH=/opt/amazon/modules/modulefiles:/usr/share/Modules/modulefiles:/etc/modulefiles
MODULESHOME=/usr/share/Modules
if command -v module &> /dev/null; then
    module load openmpi5
fi
EOF

# System-wide environment
cat > environment << 'EOF'
MODULEPATH=/opt/amazon/modules/modulefiles:/usr/share/Modules/modulefiles:/etc/modulefiles
MODULESHOME=/usr/share/Modules
PATH="/opt/amazon/openmpi5/bin:/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/home/ec2-user/.local/bin:/home/ec2-user/bin"
LD_LIBRARY_PATH="/opt/amazon/openmpi5/lib64:/opt/amazon/openmpi5/lib:/opt/amazon/efa/lib64"
EOF

# Copy the setup script to the instance using direct SSH with public IP
echo "Copying setup script to instance..."
chmod +x efa_setup.sh mpi_efa_env.sh bashrc environment
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" efa_setup.sh mpi_efa_env.sh bashrc environment mpi_pingpong_test.c ec2-user@$INSTANCE_IP:~/

# Update and reboot
update_and_reboot_instance "$KEY_FILE" "$INSTANCE_IP"

# Execute the setup script via SSH with public IP
echo "Executing EFA setup script on instance..."
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "chmod +x ~/efa_setup.sh && ~/efa_setup.sh"
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "sudo tee /etc/profile.d/mpi_efa_env.sh < ~/mpi_efa_env.sh"
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "cat ~/bashrc >> ~/.bashrc"
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "sudo tee -a /etc/environment < ~/environment"

# Update and reboot
update_and_reboot_instance "$KEY_FILE" "$INSTANCE_IP"

# Execute the setup script again
echo "Executing EFA setup script on instance..."
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" "chmod +x ~/efa_setup.sh && ~/efa_setup.sh"

# Update and reboot
update_and_reboot_instance "$KEY_FILE" "$INSTANCE_IP"

# Additional ping pong test
ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ec2-user@"$INSTANCE_IP" '
mpicc mpi_pingpong_test.c -o mpi_pingpong_test
echo "Running with default MPI configuration:"
mpirun -n 2 ./mpi_pingpong_test
echo -e "\nRunning with EFA-specific configuration:"
mpirun -n 2 \
    --mca pml ^cm \
    --mca btl ^openib,tcp \
    --mca ofi_domain_nics efa0 \
    ./mpi_pingpong_test
'

# Create an EFA-enabled AMI
echo "Creating EFA-enabled AMI..."
AMI_NAME="EFA-Enabled-AMI-$(date +%Y%m%d-%H%M%S)"
AMI_ID=$(aws ec2 create-image \
    --instance-id $INSTANCE_ID \
    --name "$AMI_NAME" \
    --description "AMI with EFA enabled" \
    --profile $PROFILE \
    --region $REGION \
    --output text \
    --query 'ImageId')
echo "EFA-enabled AMI creation initiated: $AMI_ID"
echo "Waiting for AMI to be available..."
aws ec2 wait image-available \
    --image-ids $AMI_ID \
    --profile $PROFILE \
    --region $REGION
echo "AMI is now available: $AMI_ID"

# Terminate the temporary instance
echo "Terminating temporary instance..."
aws ec2 terminate-instances \
    --instance-ids $INSTANCE_ID \
    --profile $PROFILE \
    --region $REGION

echo "Process completed successfully!"
echo "EFA-enabled AMI ID: $AMI_ID"
