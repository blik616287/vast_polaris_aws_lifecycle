# ---- VMS connection ----
variable "vms_host" {
  type = string
}

variable "vms_port" {
  type    = number
  default = 443
}

variable "vms_api_token" {
  type      = string
  default   = null
  sensitive = true
}

variable "vms_username" {
  type    = string
  default = null
}

variable "vms_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "vms_skip_ssl_verify" {
  type    = bool
  default = true
}

# ---- QoS tiers (Bronze/Silver/Gold). Limits in MB/s and IOPS. 0 = unlimited. ----
variable "qos_tiers" {
  description = "Named QoS tiers applied per tenant. Max = sustained, Burst = temporary spike."
  type = map(object({
    max_reads_bw_mbps  = number
    max_writes_bw_mbps = number
    max_reads_iops     = number
    max_writes_iops    = number
    burst_reads_bw_mb  = number
    burst_writes_bw_mb = number
    is_gold            = bool
  }))
  default = {
    bronze = { max_reads_bw_mbps = 2000, max_writes_bw_mbps = 1000, max_reads_iops = 50000, max_writes_iops = 25000, burst_reads_bw_mb = 4000, burst_writes_bw_mb = 2000, is_gold = false }
    silver = { max_reads_bw_mbps = 6000, max_writes_bw_mbps = 3000, max_reads_iops = 150000, max_writes_iops = 75000, burst_reads_bw_mb = 12000, burst_writes_bw_mb = 6000, is_gold = false }
    gold   = { max_reads_bw_mbps = 20000, max_writes_bw_mbps = 10000, max_reads_iops = 500000, max_writes_iops = 250000, burst_reads_bw_mb = 40000, burst_writes_bw_mb = 20000, is_gold = true }
  }
}

# ---- One entry per Palette Project/Workspace = one VAST tenant ----
variable "tenants" {
  description = "Palette tenant -> VAST tenant + VIP pool + QoS + NFS view."
  type = map(object({
    client_ip_ranges = list(list(string)) # [["start","end"]] worker source IPs
    vip_ip_ranges    = list(list(string)) # [["start","end"]] data VIPs for this tenant
    subnet_cidr      = number             # CIDR prefix length of the data network
    qos_tier         = string             # key into qos_tiers
    storage_path     = string             # base Element Store path for the view
    nfs_read_write   = list(string)       # client CIDRs allowed RW on the view
    vlan             = optional(number)   # optional VLAN tag for network isolation
  }))
  default = {
    # team-alpha = {
    #   client_ip_ranges = [["172.20.20.10", "172.20.20.250"]]
    #   vip_ip_ranges    = [["10.20.0.20", "10.20.0.40"]]
    #   subnet_cidr      = 16
    #   qos_tier         = "gold"
    #   storage_path     = "/k8s/team-alpha"
    #   nfs_read_write   = ["172.20.20.0/22"]
    # }
  }
}
