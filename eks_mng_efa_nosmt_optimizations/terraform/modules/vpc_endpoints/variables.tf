variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "control_plane_sg" {
  description = "Control plane security group ID"
  type        = string
}

variable "cluster_sg" {
  description = "Cluster security group ID"
  type        = string
}

variable "efa_sg" {
  description = "EFA security group ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
