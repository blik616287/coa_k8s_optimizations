output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks_cluster.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks_cluster.api_server_url
}

output "eks_cluster_certificate_authority_data" {
  description = "EKS cluster certificate authority data"
  value       = module.eks_cluster.b64_cluster_ca
  sensitive   = true
}

output "nodegroup_name" {
  description = "EKS nodegroup name"
  value       = module.nodegroup.nodegroup_name
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = module.eks_cluster.oidc_provider_arn
}

output "control_plane_sg_id" {
  description = "Control plane security group ID"
  value       = module.eks_cluster.control_plane_sg_id
}

output "cluster_sg_id" {
  description = "Cluster security group ID"
  value       = module.eks_cluster.cluster_sg_id
}

output "shared_node_sg_id" {
  description = "Shared node security group ID"
  value       = module.eks_cluster.shared_node_sg_id
}

output "efa_sg_id" {
  description = "EFA security group ID"
  value       = module.nodegroup.efa_sg_id
}

output "placement_group_name" {
  description = "EC2 placement group name"
  value       = module.nodegroup.placement_group_name
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = module.nodegroup.launch_template_id
}
