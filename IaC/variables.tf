variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production"
  }
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "allowed_cidrs" {
  type        = list(string)
  description = "HTTP ingress CIDRs; the deploy script defaults this to your current public IP/32."
}
variable "image" {
  type        = string
  description = "Immutable GHCR image tag built by GitHub Actions."
}
variable "github_oidc_provider_arn" {
  type        = string
  description = "ARN output by terraform/bootstrap."
}
variable "github_oidc_subject" {
  type        = string
  description = "Exact GitHub OIDC subject for this repository's main branch."
}

variable "ghcr_username" {
  type        = string
  description = "GitHub username that owns the read:packages token stored in SSM."
}
