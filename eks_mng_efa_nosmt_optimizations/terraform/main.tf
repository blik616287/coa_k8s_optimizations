provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  cluster_name = var.cluster_name
  tags = {
    Name    = "eksctl-${local.cluster_name}-cluster"
    Cluster = local.cluster_name
  }
}

# Get instance type information
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# Create EKS Cluster
module "eks_cluster" {
  source = "./modules/eks_cluster"

  cluster_name         = local.cluster_name
  eks_version          = var.eks_version
  vpc_id               = var.vpc_id
  private_subnet_ids   = [var.private_subnet_a, var.private_subnet_b]
  tags                 = local.tags
}

# Create VPC Endpoints
module "vpc_endpoints" {
  source = "./modules/vpc_endpoints"

  vpc_id             = var.vpc_id
  cluster_name       = local.cluster_name
  private_subnet_ids = [var.private_subnet_a, var.private_subnet_b]
  control_plane_sg   = module.eks_cluster.control_plane_sg_id
  cluster_sg         = module.eks_cluster.cluster_sg_id
  efa_sg             = module.nodegroup.efa_sg_id
  aws_region         = var.aws_region
  tags               = local.tags

  depends_on = [module.eks_cluster, module.nodegroup]
}

# Create nodegroup with EFA
module "nodegroup" {
  source = "./modules/nodegroup"

  cluster_name      = local.cluster_name
  nodegroup_name    = var.nodegroup_name
  vpc_id            = var.vpc_id
  private_subnet_ids = [var.private_subnet_a]
  instance_type     = var.instance_type
  core_count        = data.aws_ec2_instance_type.selected.default_cores
  cluster_sg_id     = module.eks_cluster.cluster_sg_id
  oidc_provider_arn = module.eks_cluster.oidc_provider_arn
  tags              = local.tags
  api_server_url    = module.eks_cluster.api_server_url
  b64_cluster_ca    = module.eks_cluster.b64_cluster_ca

  depends_on = [module.eks_cluster]
}

# Install EFA Device Plugin
resource "null_resource" "aws_efa_k8s_device_plugin" {
  provisioner "local-exec" {
    command = <<-EOT
      helm repo add eks https://aws.github.io/eks-charts
      helm install aws-efa-k8s-device-plugin --namespace kube-system eks/aws-efa-k8s-device-plugin
    EOT
  }

  depends_on = [module.eks_cluster, module.nodegroup]
}
