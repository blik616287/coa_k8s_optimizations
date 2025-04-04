# Security Group for VPC Endpoints
resource "aws_security_group" "vpc_endpoint_sg" {
  name        = "eks-endpoint-sg-${var.cluster_name}-custom"
  description = "Security group for EKS VPC endpoints"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc-endpoint-sg"
  })
}

resource "aws_security_group_rule" "endpoint_ingress_from_control_plane" {
  security_group_id        = aws_security_group.vpc_endpoint_sg.id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.control_plane_sg
  description              = "Allow HTTPS from EKS control plane"
}

resource "aws_security_group_rule" "endpoint_ingress_from_cluster" {
  security_group_id        = aws_security_group.vpc_endpoint_sg.id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.cluster_sg
  description              = "Allow HTTPS from EKS cluster"
}

resource "aws_security_group_rule" "endpoint_ingress_from_efa" {
  security_group_id        = aws_security_group.vpc_endpoint_sg.id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.efa_sg
  description              = "Allow HTTPS from EFA security group"
}

# Get route tables for S3 gateway endpoint
data "aws_route_tables" "vpc_route_tables" {
  vpc_id = var.vpc_id
}

# EC2 interface endpoint
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ec2-endpoint"
    Cluster = var.cluster_name
  })
}

# ECR API interface endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ecr-api-endpoint"
    Cluster = var.cluster_name
  })
}

# ECR DKR interface endpoint
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ecr-dkr-endpoint"
    Cluster = var.cluster_name
  })
}

# S3 gateway endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.vpc_route_tables.ids

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-s3-endpoint"
    Cluster = var.cluster_name
  })
}

# EKS interface endpoint
resource "aws_vpc_endpoint" "eks" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.eks"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-eks-endpoint"
    Cluster = var.cluster_name
  })
}

# STS interface endpoint
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-sts-endpoint"
    Cluster = var.cluster_name
  })
}

# CloudWatch Logs interface endpoint
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-logs-endpoint"
    Cluster = var.cluster_name
  })
}

# SSM interface endpoint
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ssm-endpoint"
    Cluster = var.cluster_name
  })
}

# SSM Messages interface endpoint
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ssmmessages-endpoint"
    Cluster = var.cluster_name
  })
}

# EC2 Messages interface endpoint
resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-ec2messages-endpoint"
    Cluster = var.cluster_name
  })
}

# Update security group ingress rules for SSM endpoints
resource "aws_security_group_rule" "ssm_ingress_from_cluster" {
  security_group_id        = aws_vpc_endpoint.ssm.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.cluster_sg
  description              = "Allow HTTPS from cluster security group"
}

resource "aws_security_group_rule" "ssm_ingress_from_efa" {
  security_group_id        = aws_vpc_endpoint.ssm.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.efa_sg
  description              = "Allow HTTPS from EFA security group"
}

resource "aws_security_group_rule" "ssmmessages_ingress_from_cluster" {
  security_group_id        = aws_vpc_endpoint.ssmmessages.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.cluster_sg
  description              = "Allow HTTPS from cluster security group"
}

resource "aws_security_group_rule" "ssmmessages_ingress_from_efa" {
  security_group_id        = aws_vpc_endpoint.ssmmessages.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.efa_sg
  description              = "Allow HTTPS from EFA security group"
}

resource "aws_security_group_rule" "ec2messages_ingress_from_cluster" {
  security_group_id        = aws_vpc_endpoint.ec2messages.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.cluster_sg
  description              = "Allow HTTPS from cluster security group"
}

resource "aws_security_group_rule" "ec2messages_ingress_from_efa" {
  security_group_id        = aws_vpc_endpoint.ec2messages.security_groups[0]
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.efa_sg
  description              = "Allow HTTPS from EFA security group"
}
