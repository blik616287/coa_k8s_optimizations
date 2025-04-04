locals {
  eks_node_role_name = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}-NodeInstanceRole"
}

# IAM role for the Node Group
resource "aws_iam_role" "node_instance_role" {
  name = local.eks_node_role_name
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}/NodeInstanceRole"
  })
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  role       = aws_iam_role.node_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_policy" {
  role       = aws_iam_role.node_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.node_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 Placement Group
resource "aws_placement_group" "nodegroup" {
  name     = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}-NodeGroupPlacementGroup"
  strategy = "cluster"
}

# EFA Security Group
resource "aws_security_group" "efa_sg" {
  name        = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}-EFASG"
  description = "EFA-enabled security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name                        = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}/EFASG"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

resource "aws_security_group_rule" "efa_ingress_self" {
  security_group_id        = aws_security_group.efa_sg.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.efa_sg.id
  description              = "Allow worker nodes in group ${var.nodegroup_name} to communicate to itself (EFA-enabled)"
}

resource "aws_security_group_rule" "efa_egress_self" {
  security_group_id        = aws_security_group.efa_sg.id
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.efa_sg.id
  description              = "Allow worker nodes in group ${var.nodegroup_name} to communicate to itself (EFA-enabled)"
}

# Launch template 
resource "aws_launch_template" "nodegroup" {
  name = "eksctl-${var.cluster_name}-nodegroup-${var.nodegroup_name}"

  network_interfaces {
    device_index       = 0
    security_groups    = [var.cluster_sg_id, aws_security_group.efa_sg.id]
    interface_type     = "efa"
    network_card_index = 0
  }

  cpu_options {
    core_count       = var.core_count
    threads_per_core = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 400
      volume_type = "gp3"
      iops        = 3000
      throughput  = 125
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  placement {
    group_name = aws_placement_group.nodegroup.name
  }

  user_data = base64encode(templatefile("${path.module}/user-data.tpl", {
    cluster_name   = var.cluster_name
    api_server_url = var.api_server_url
    b64_cluster_ca = var.b64_cluster_ca
    nodegroup_name = var.nodegroup_name
  }))

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name                            = "${var.cluster_name}-${var.nodegroup_name}-Node"
      "alpha.eksctl.io/nodegroup-name" = var.nodegroup_name
      "alpha.eksctl.io/nodegroup-type" = "managed"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name                            = "${var.cluster_name}-${var.nodegroup_name}-Node"
      "alpha.eksctl.io/nodegroup-name" = var.nodegroup_name
      "alpha.eksctl.io/nodegroup-type" = "managed"
    }
  }

  tag_specifications {
    resource_type = "network-interface"

    tags = {
      Name                            = "${var.cluster_name}-${var.nodegroup_name}-Node"
      "alpha.eksctl.io/nodegroup-name" = var.nodegroup_name
      "alpha.eksctl.io/nodegroup-type" = "managed"
    }
  }
}

# EKS Managed Node Group
resource "aws_eks_node_group" "nodegroup" {
  cluster_name    = var.cluster_name
  node_group_name = var.nodegroup_name
  node_role_arn   = aws_iam_role.node_instance_role.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.nodegroup.id
    version = aws_launch_template.nodegroup.latest_version
  }

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  labels = {
    "alpha.eksctl.io/cluster-name"   = var.cluster_name
    "alpha.eksctl.io/nodegroup-name" = var.nodegroup_name
  }

  tags = {
    "alpha.eksctl.io/nodegroup-name" = var.nodegroup_name
    "alpha.eksctl.io/nodegroup-type" = "managed"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.ecr_policy,
    aws_iam_role_policy_attachment.ssm_policy,
  ]
}
