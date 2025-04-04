output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.eks.name
}

output "api_server_url" {
  description = "API server URL"
  value       = aws_eks_cluster.eks.endpoint
}

output "b64_cluster_ca" {
  description = "Base64 encoded cluster CA certificate"
  value       = aws_eks_cluster.eks.certificate_authority[0].data
  sensitive   = true
}

output "control_plane_sg_id" {
  description = "Control plane security group ID"
  value       = aws_security_group.control_plane_sg.id
}

output "shared_node_sg_id" {
  description = "Shared node security group ID"
  value       = aws_security_group.shared_node_sg.id
}

output "cluster_sg_id" {
  description = "Cluster security group ID"
  value       = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL"
  value       = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

output "vpc_cni_role_arn" {
  description = "VPC CNI role ARN"
  value       = aws_iam_role.vpc_cni.arn
}
