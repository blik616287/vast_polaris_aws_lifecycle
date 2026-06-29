# ---------- Provider / environment ----------
variable "aws_profile" {
  type    = string
  default = "fieldeng"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "environment" {
  type        = string
  default     = "fieldeng"
  description = "Name suffix/tag for all resources."
}

# ---------- VAST VPC ----------
variable "vast_vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR for the dedicated VAST VPC. Must not overlap any peered VPC."
}

variable "azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "private_subnet_newbits" {
  type    = number
  default = 4
}

variable "public_subnet_newbits" {
  type    = number
  default = 8
}

variable "single_nat" {
  type        = bool
  default     = true
  description = "true = one NAT (cheaper); false = one NAT per AZ (HA)."
}

# ---------- Client access ----------
# Source CIDRs allowed to reach VAST (VIPs + VMS). Defaults to the VAST VPC
# itself (clients in-VPC). Add your k8s/EKS worker subnet CIDRs here, and/or
# enable peering below.
variable "vast_client_cidrs" {
  type    = list(string)
  default = []
}

# ---------- Optional VPC peering ----------
# In a greenfield account (e.g. fieldeng) there is no Palette VPC to peer to,
# so peering is OFF by default. Turn it on to connect to an existing k8s VPC.
variable "enable_peering" {
  type    = bool
  default = false
}

variable "peer_vpc_id" {
  type    = string
  default = ""
}

variable "peer_vpc_cidr" {
  type    = string
  default = ""
}

variable "peer_route_table_ids" {
  type        = list(string)
  default     = []
  description = "Route tables in the peered VPC that need a return route to the VAST VPC."
}

# ---------- VAST client ports (confirm S3/NVMe-TCP with VAST) ----------
variable "vast_nfs_ports" {
  type    = list(number)
  default = [2049, 111, 20048, 20106, 20107, 20108]
}

variable "vast_mgmt_ports" {
  type    = list(number)
  default = [443, 80]
}

variable "vast_nvme_ports" {
  type = list(number)
  # 4420 = NVMe-oF I/O, 4520 = NVMe-oF (alt), 8009 = NVMe-oF DISCOVERY.
  # 8009 is REQUIRED for block/NVMe-TCP: the VAST CSI block driver's `nvme
  # connect-all` contacts the discovery controller on 8009 (per VAST KB
  # "Configuring an NVMe/TCP Client on Linux"). Without it the driver's connect
  # times out (NodeStageVolume "Failed to write to /dev/nvme-fabrics: timed out")
  # even though raw 4420 is reachable.
  default = [4420, 4520, 8009]
}

variable "vast_ssh_port" {
  type    = number
  default = 22
}
