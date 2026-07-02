variable "region" {
  type    = string
  default = "us-east-2"
}

variable "fieldeng_profile" {
  type    = string
  default = "fieldeng"
}

# ---- this tenant's peer VPC (set per-workspace via *.tfvars) ----
variable "name" {
  description = "Name prefix for this tenant's VPC + resources, e.g. voc-tenant-1."
  type        = string
}

variable "cidr" {
  description = "CIDR for this tenant's peer VPC. MUST NOT overlap 10.20/16 (VAST) or 10.30/16 (spectro peer) or the other tenant."
  type        = string
}

variable "azs" {
  description = "AZs for the subnets (Palette managed clusters want >=2 for the control-plane LB)."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "single_nat" {
  description = "One NAT gateway for all private subnets (cheaper) vs one per AZ."
  type        = bool
  default     = true
}

# ---- fieldeng VAST side to peer into (from the main voc apply) ----
variable "vast_vpc_id" {
  description = "fieldeng VAST VPC id to peer into."
  type        = string
  default     = "vpc-0ff881160438da5dd"
}

variable "vast_vpc_cidr" {
  description = "fieldeng VAST VPC CIDR (CSI/VMS target range)."
  type        = string
  default     = "10.20.0.0/16"
}
