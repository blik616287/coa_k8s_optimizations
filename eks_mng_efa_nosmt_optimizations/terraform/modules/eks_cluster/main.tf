resource "aws_security_group" "control_plane_sg" {
  name        = "eksctl-${var.cluster_name}-cluster-ControlPlaneSecurityGroup"
  description = "Communication between the control plane and worker nodegroups"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "eksctl-${var.cluster_name}-cluster/ControlPlaneSecurityGroup"
  })
}

resource "aws_security_group" "shared_node_sg" {
  name        = "eksctl-${var.cluster_name}-cluster-ClusterSharedNodeSecurityGroup"
  description = "Communication between all nodes in the cluster"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "eksctl-${var.cluster_name}-cluster/ClusterSharedNodeSecurityGroup"
  })
}

resource "aws_security_group_rule" "shared_node_ingress_self" {
  security_group_id        = aws_security_group.shared_node_sg.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.shared_node_sg.id
  description              = "Allow nodes to communicate with each other (all ports)"
}

# This will be updated once we have the cluster security group ID
resource "aws_security_group_rule" "shared_node_ingress_cluster" {
  security_group_id        = aws_security_group.shared_node_sg.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
  description              = "Allow managed and unmanaged nodes to communicate with each other (all ports)"

  depends_on = [aws_eks_cluster.eks]
}

# IAM role for EKS cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eksctl-${var.cluster_name}-cluster-ServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "eksctl-${var.cluster_name}-cluster/ServiceRole"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Create EKS cluster
resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.control_plane_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, {
    Name = "eksctl-${var.cluster_name}-cluster/ControlPlane"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# Allow communication between shared node SG and cluster SG
resource "aws_security_group_rule" "cluster_to_shared_node" {
  security_group_id        = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.shared_node_sg.id
  description              = "Allow unmanaged nodes to communicate with control plane (all ports)"
}

# Create OIDC provider for the cluster
data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

# Create IAM role for VPC CNI with OIDC
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "vpc_cni" {
  name = "eksctl-${var.cluster_name}-addon-vpc-cni-Role1"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com",
            "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Create EKS addons
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_cluster.eks]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "coredns"

  depends_on = [aws_eks_cluster.eks]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.eks.name
  addon_name               = "vpc-cni"
  service_account_role_arn = aws_iam_role.vpc_cni.arn

  depends_on = [aws_eks_cluster.eks, aws_iam_role.vpc_cni]
}
