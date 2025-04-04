# EKS HPC Cluster with EFA Terraform Project

This Terraform project creates an Amazon EKS cluster optimized for High Performance Computing (HPC) workloads, with Elastic Fabric Adapter (EFA) support.

## Features

- Creates an EKS cluster with version 1.32
- Sets up VPC endpoints for private cluster access
- Creates an EFA-enabled nodegroup with c5n.9xlarge instances (customizable)
- Configures the nodegroup for HPC workloads:
  - CPU Manager Policy set to static
  - IRQ affinity optimization
  - Huge pages configuration
  - Transparent hugepage disabled
  - System tuning for HPC workloads
- Installs the AWS EFA Kubernetes device plugin

## Project Structure

```
.
├── main.tf                 # Main Terraform configuration file
├── variables.tf            # Input variables
├── outputs.tf              # Output values
├── modules/
    ├── eks_cluster/        # EKS cluster configuration
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── nodegroup/          # EFA-enabled nodegroup
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── user-data.tpl   # User data template for node configuration
    └── vpc_endpoints/      # VPC endpoints for private cluster access
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## Prerequisites

- AWS CLI configured with appropriate credentials and profile
- Terraform v1.0.0 or newer
- Helm (for installing the EFA device plugin)
- kubectl (for interacting with the cluster)

## Usage

1. Initialize the Terraform project:

```bash
terraform init
```

2. Review the execution plan:

```bash
terraform plan
```

3. Apply the Terraform configuration:

```bash
terraform apply
```

4. Configure kubectl to interact with the cluster:

```bash
aws eks update-kubeconfig --name <cluster_name> --region <region> --profile <profile>
```

## Customization

You can customize the deployment by modifying the variables in `variables.tf` or by providing values at runtime:

```bash
terraform apply -var="cluster_name=my-hpc-cluster" -var="instance_type=p4d.24xlarge"
```

Key variables you might want to customize:

- `cluster_name`: Name of the EKS cluster
- `nodegroup_name`: Name of the EFA nodegroup
- `instance_type`: EC2 instance type for the nodegroup
- `aws_region`: AWS region for deployment
- `aws_profile`: AWS CLI profile to use
- `vpc_id`: VPC ID to deploy into
- `private_subnet_a` and `private_subnet_b`: Subnet IDs for the cluster

## Clean up

To destroy all resources created by this Terraform project:

```bash
terraform destroy
```

## Notes

- This project assumes you have pre-existing VPC and subnets
- The EKS cluster is configured with both public and private endpoint access
- The nodegroup is placed in a cluster placement group for optimal networking performance
- The user data script configures the nodes for HPC workloads, including IRQ affinity and CPU isolation
- The project uses the AWS EFA Kubernetes device plugin to expose EFA interfaces to pods
