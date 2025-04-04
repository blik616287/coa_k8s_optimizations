output "nodegroup_name" {
  description = "EKS nodegroup name"
  value       = aws_eks_node_group.nodegroup.node_group_name
}

output "efa_sg_id" {
  description = "EFA security group ID"
  value       = aws_security_group.efa_sg.id
}

output "placement_group_name" {
  description = "EC2 placement group name"
  value       = aws_placement_group.nodegroup.name
}

output "node_role_arn" {
  description = "Node IAM role ARN"
  value       = aws_iam_role.node_instance_role.arn
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.nodegroup.id
}
