terraform {
  required_version = ">= 1.5"
  required_providers {
    vastdata = {
      source  = "vast-data/vastdata"
      version = "~> 3.2" # 3.2.2+ recommended (fixes VIEW QoS drift)
    }
  }
}

# Reachable once a VoC cluster exists and the VMS endpoint is routable from where
# Terraform runs. Use a scoped "manager" API token, NOT root admin.
provider "vastdata" {
  host            = var.vms_host      # e.g. 10.20.x.x  (VMS VIP)
  port            = var.vms_port      # default 443
  api_token       = var.vms_api_token # OR username/password below
  username        = var.vms_username
  password        = var.vms_password
  skip_ssl_verify = var.vms_skip_ssl_verify
}
