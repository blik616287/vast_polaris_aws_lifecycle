terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state (recommended). Create the bucket+lock table once, then uncomment.
  # backend "s3" {
  #   bucket         = "vast-voc-tfstate-211476615597"
  #   key            = "voc/network/terraform.tfstate"
  #   region         = "us-east-2"
  #   dynamodb_table = "vast-voc-tflock"
  #   profile        = "fieldeng"
  #   encrypt        = true
  # }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = {
      Project     = "vast-voc"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
