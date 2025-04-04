variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS profile"
  type        = string
  default     = "coa"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = "vpc-07b388829583e6dc7"
}

variable "private_subnet_a" {
  description = "Private subnet A ID"
  type        = string
  default     = "subnet-0bdd69129d90bf460"
}

variable "private_subnet_b" {
  description = "Private subnet B ID"
  type        = string
  default     = "subnet-0bb4f4ad200d15838"
}

variable "eks_version" {
  description = "EKS version"
  type        = string
  default     = "1.32"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "mforde-hpc"
}

variable "nodegroup_name" {
  description = "EKS nodegroup name"
  type        = string
  default     = "my-efa-ng27"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "c5n.9xlarge"
}
