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
