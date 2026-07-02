# =============================================================================
# Same-account peer VPCs for VoC tenancy + peering testing.
#
# Reuses the spectro-peering/ resource pattern, but single-account: the peer VPC,
# the VAST VPC, and the peering all live in fieldeng. Driven by terraform
# WORKSPACES — one workspace (= one state) per tenant VPC, so each run is tracked
# and destroyed independently:
#
#   terraform workspace new tenant-1 && terraform apply -var-file=tenant-1.tfvars
#   terraform workspace new tenant-2 && terraform apply -var-file=tenant-2.tfvars
#
# Pairs with the main voc apply: add each tenant CIDR to vast_client_cidrs there so
# the VAST SG opens client ports to it (this root adds the VPC + peering + routes).
# Workflow: terraform plan -> review -> apply (never auto-apply).
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.fieldeng_profile
  default_tags {
    tags = {
      Project   = "vast-voc"
      Purpose   = "voc-tenant-peering-test"
      ManagedBy = "terraform"
    }
  }
}
