variable "region" {
  type    = string
  default = "us-east-2"
}

variable "spectro_profile" {
  type    = string
  default = "spectro"
}

variable "fieldeng_profile" {
  type    = string
  default = "fieldeng"
}

variable "fieldeng_account_id" {
  description = "AWS account id that owns the VAST VPC (fieldeng)."
  type        = string
  default     = "211476615597"
}

# ---- fieldeng VAST side (from the main voc apply outputs) ----
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

# ---- new spectro test VPC ----
variable "spectro_test_cidr" {
  description = "CIDR for the new spectro test VPC. MUST NOT overlap the VAST VPC (10.20/16), the spectro Palette VPC (172.20/16), or the spectro vast-voc-ue2 VPC (10.20/16)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "azs" {
  description = "AZs for the test VPC subnets (Palette managed clusters want >=2 for the control-plane LB)."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "single_nat" {
  description = "One NAT gateway for all private subnets (cheaper) vs one per AZ."
  type        = bool
  default     = true
}
