variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "nodegroup_name" {
  description = "EKS nodegroup name"
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

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "core_count" {
  description = "Number of CPU cores"
  type        = number
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "api_server_url" {
  description = "API server URL"
  type        = string
}

variable "b64_cluster_ca" {
  description = "Base64 encoded cluster CA certificate"
  type        = string
  sensitive   = true
}
