terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {}
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type = string
}

variable "image_uri" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "cluster_version" {
  type    = string
  default = "1.32"
}

variable "desired_node_count" {
  type    = number
  default = 2
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# ECR Repository
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app_repo" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "app-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app-vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.app-vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-public-a"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "shared"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.app-vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-public-b"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "shared"
  }
}

# Private Subnets
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.app-vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name                              = "${var.project_name}-private-a"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "owned"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.app-vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name                              = "${var.project_name}-private-b"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "owned"
  }
}

# NAT Gateway for private subnets
resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-a"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-b"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${var.project_name}-nat-a"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id

  tags = {
    Name = "${var.project_name}-nat-b"
  }

  depends_on = [aws_internet_gateway.igw]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.app-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.app-vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }

  tags = {
    Name = "${var.project_name}-private-rt-a"
  }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.app-vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id
  }

  tags = {
    Name = "${var.project_name}-private-rt-b"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# ---------------------------------------------------------------------------
# IAM for EKS Cluster
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
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

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "app-cluster" {
  name     = "${var.project_name}-cluster"
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_vpc.app-vpc,
    aws_subnet.private_a,
    aws_subnet.private_b,
    aws_internet_gateway.igw,
  ]

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# ---------------------------------------------------------------------------
# IAM for EKS Node Group
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_node_role" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---------------------------------------------------------------------------
# EKS Node Group
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "app-nodes" {
  cluster_name    = aws_eks_cluster.app-cluster.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types  = [var.instance_type]

  scaling_config {
    desired_size = var.desired_node_count
    max_size     = 4
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_eks_cluster.app-cluster,
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]

  tags = {
    Name = "${var.project_name}-nodes"
  }
}

# ---------------------------------------------------------------------------
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# ---------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.app-cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.app-cluster.identity[0].oidc[0].issuer
}

# ---------------------------------------------------------------------------
# IAM Role for AWS Load Balancer Controller
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks_oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller_role" {
  name               = "${var.project_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json
}

resource "aws_iam_policy" "alb_controller_policy" {
  name   = "${var.project_name}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller_attachment" {
  role       = aws_iam_role.alb_controller_role.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}

# ---------------------------------------------------------------------------
# Kubernetes + Helm providers
#
# IMPORTANT: these providers must be configured via data sources, NOT via
# direct references to the aws_eks_cluster managed resource.
#
# Terraform initialises provider configurations before the state-refresh
# phase. If the kubernetes/helm provider blocks reference a managed resource
# attribute (e.g. aws_eks_cluster.app-cluster.endpoint), that attribute is
# an empty string at provider-init time (the resource hasn't been read from
# state yet), so the kubernetes provider falls back to http://localhost:80
# and fails with "connection refused" when trying to refresh or destroy any
# kubernetes_* resource.
#
# data "aws_eks_cluster" / data "aws_eks_cluster_auth" make a live AWS API
# call when evaluated, so the real endpoint is always returned for both
# apply and destroy operations.
# ---------------------------------------------------------------------------
data "aws_eks_cluster" "app_cluster_data" {
  name       = aws_eks_cluster.app-cluster.name
  depends_on = [aws_eks_cluster.app-cluster]
}

data "aws_eks_cluster_auth" "app_cluster_auth" {
  name       = aws_eks_cluster.app-cluster.name
  depends_on = [aws_eks_cluster.app-cluster]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.app_cluster_data.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.app_cluster_data.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.app_cluster_auth.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.app_cluster_data.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.app_cluster_data.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.app_cluster_auth.token
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller via Helm
# ---------------------------------------------------------------------------
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.app-cluster.name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller_role.arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = aws_vpc.app-vpc.id
  }

  depends_on = [
    aws_eks_node_group.app-nodes,
    aws_iam_role_policy_attachment.alb_controller_attachment,
    aws_iam_openid_connect_provider.eks_oidc,
  ]
}

# ---------------------------------------------------------------------------
# Kubernetes Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "app" {
  metadata {
    name = var.project_name
    labels = {
      name = var.project_name
    }
  }

  depends_on = [aws_eks_node_group.app-nodes]
}

# ---------------------------------------------------------------------------
# Kubernetes Deployment
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "app" {
  metadata {
    name      = "${var.project_name}-deployment"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = var.project_name
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = var.project_name
      }
    }

    template {
      metadata {
        labels = {
          app = var.project_name
        }
      }

      spec {
        container {
          name  = var.project_name
          image = var.image_uri

          port {
            container_port = 8000
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health/"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/health/"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace.app,
  ]
}

# ---------------------------------------------------------------------------
# Kubernetes Service
# ---------------------------------------------------------------------------
resource "kubernetes_service" "app" {
  metadata {
    name      = "${var.project_name}-service"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = var.project_name
    }
  }

  spec {
    selector = {
      app = var.project_name
    }

    port {
      port        = 80
      target_port = 8000
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_namespace.app]
}

# ---------------------------------------------------------------------------
# Kubernetes Ingress
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = "${var.project_name}-ingress"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/health/"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.app.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_service.app,
  ]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "ecr_repository_url" {
  value = aws_ecr_repository.app_repo.repository_url
}

output "eks_cluster_name" {
  value = aws_eks_cluster.app-cluster.name
}

output "alb_hostname" {
  value = try(kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "app_url" {
  value = "http://${try(kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname, "")}"
}
