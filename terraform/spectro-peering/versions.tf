terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Default provider = spectro account (216938125181): hosts the new, non-overlapping
# test VPC and the peering requester.
provider "aws" {
  region  = var.region
  profile = var.spectro_profile
  default_tags {
    tags = {
      Project   = "vast-voc"
      Purpose   = "spectro-csi-test"
      ManagedBy = "terraform"
    }
  }
}

# fieldeng account (211476615597): owns the VAST VPC. Accepts the peering and adds
# the return routes so the VAST nodes can reply to the spectro test cluster.
provider "aws" {
  alias   = "fieldeng"
  region  = var.region
  profile = var.fieldeng_profile
}
