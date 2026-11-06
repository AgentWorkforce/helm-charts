locals {
  role_services = { cluster = "eks.amazonaws.com", node = "ec2.amazonaws.com", cni = "pods.eks.amazonaws.com", ebs = "pods.eks.amazonaws.com" }
  managed_policies = {
    cluster = { role = "cluster", policy = "AmazonEKSClusterPolicy" }
    node    = { role = "node", policy = "AmazonEKSWorkerNodePolicy" }
    image   = { role = "node", policy = "AmazonEC2ContainerRegistryPullOnly" }
    cni     = { role = "cni", policy = "AmazonEKS_CNI_Policy" }
    ebs     = { role = "ebs", policy = "AmazonEBSCSIDriverPolicyV2" }
  }
}
resource "aws_iam_role" "this" {
  for_each             = local.role_services
  name                 = "${local.name}-${each.key}"
  path                 = local.role_path
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [merge({
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = contains(["cni", "ebs"], each.key) ? ["sts:AssumeRole", "sts:TagSession"] : ["sts:AssumeRole"]
      }, contains(["cni", "ebs"], each.key) ? {
      Condition = {
        StringEquals = {
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = each.key == "cni" ? "aws-node" : "ebs-csi-controller-sa"
          "aws:RequestTag/eks-cluster-name"           = local.name
        }
      }
    } : {})]
  })
  tags       = local.tags
  depends_on = [terraform_data.guard]
}
resource "aws_iam_role_policy_attachment" "this" {
  for_each   = local.managed_policies
  role       = aws_iam_role.this[each.value.role].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value.policy}"
}
resource "aws_iam_role_policy" "ebs_kms" {
  name = "${local.name}-ebs-kms"
  role = aws_iam_role.this["ebs"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"], Resource = var.kms_key_arn, Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } } },
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = var.kms_key_arn }
    ]
  })
}
