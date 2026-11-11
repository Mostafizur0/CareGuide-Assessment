terraform {
  required_version = ">= 1.10.0"
  backend "s3" {}
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" { region = var.aws_region }
data "aws_caller_identity" "current" {}
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.environment}-app-"
  description = "Application HTTP ingress; outbound access for SSM and image pulls"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { App = "devops-assessment", Environment = var.environment }
}

resource "aws_iam_role" "instance" {
  name = "${var.environment}-devops-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.environment}/devops-app"
  retention_in_days = 14
}
resource "aws_iam_role_policy" "logs" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" }]
  })
}
resource "aws_iam_role_policy" "registry" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devops/ghcr-read-token" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*", Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } } }
    ]
  })
}
resource "aws_iam_instance_profile" "app" {
  role = aws_iam_role.instance.name
}
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    log_group = aws_cloudwatch_log_group.app.name
    image     = var.image
    environment = var.environment
    aws_region  = var.aws_region
    ghcr_username = var.ghcr_username
  })
  tags = { Name = "${var.environment}-devops-assessment", App = "devops-assessment", Environment = var.environment }
}

resource "aws_iam_role" "github_actions" {
  name = "${var.environment}-github-actions-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Federated = var.github_oidc_provider_arn },
      Action    = "sts:AssumeRoleWithWebIdentity",
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub" = var.github_oidc_subject
      } }
    }]
  })
}
resource "aws_iam_role_policy" "github_deploy" {
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ssm:SendCommand"],
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        Effect   = "Allow",
        Action   = ["ssm:SendCommand"],
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        Condition = { StringEquals = { "ssm:resourceTag/App" = "devops-assessment" } }
      },
      { Effect = "Allow", Action = ["ssm:GetCommandInvocation"], Resource = "*" }
    ]
  })
}

output "instance_id" { value = aws_instance.app.id }
output "public_ip" { value = aws_instance.app.public_ip }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
