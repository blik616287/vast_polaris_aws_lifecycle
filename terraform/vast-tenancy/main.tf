# =============================================================================
# Maps each Palette Project/Workspace -> a fully isolated VAST tenant:
#   tenant  ->  VIP pool (tenant-bound)  ->  QoS policy  ->  view policy  ->  view
# This is the IaC behind the Phase-2 multi-tenancy reference architecture and
# the Control-Plane doc's "API automation / VIP pools / QoS policies" rows.
# The vast-csi pack then points a per-tenant StorageClass at the VIP pool below.
# =============================================================================

resource "vastdata_tenant" "this" {
  for_each         = var.tenants
  name             = each.key
  client_ip_ranges = each.value.client_ip_ranges
}

resource "vastdata_qos_policy" "this" {
  for_each    = var.tenants
  name        = "${each.key}-${each.value.qos_tier}"
  policy_type = "VIEW"
  limit_by    = "BW_IOPS"
  is_gold     = var.qos_tiers[each.value.qos_tier].is_gold
  tenant_id   = vastdata_tenant.this[each.key].id

  static_limits = {
    max_reads_bw_mbps  = var.qos_tiers[each.value.qos_tier].max_reads_bw_mbps
    max_writes_bw_mbps = var.qos_tiers[each.value.qos_tier].max_writes_bw_mbps
    max_reads_iops     = var.qos_tiers[each.value.qos_tier].max_reads_iops
    max_writes_iops    = var.qos_tiers[each.value.qos_tier].max_writes_iops
    burst_reads_bw_mb  = var.qos_tiers[each.value.qos_tier].burst_reads_bw_mb
    burst_writes_bw_mb = var.qos_tiers[each.value.qos_tier].burst_writes_bw_mb
  }
}

resource "vastdata_vip_pool" "this" {
  for_each    = var.tenants
  name        = "${each.key}-pool"
  role        = "PROTOCOLS"
  subnet_cidr = each.value.subnet_cidr
  ip_ranges   = each.value.vip_ip_ranges
  tenant_id   = vastdata_tenant.this[each.key].id
  vlan        = try(each.value.vlan, null)
}

resource "vastdata_view_policy" "this" {
  for_each       = var.tenants
  name           = "${each.key}-policy"
  flavor         = "NFS"
  nfs_read_write = each.value.nfs_read_write
}

resource "vastdata_view" "this" {
  for_each      = var.tenants
  path          = each.value.storage_path
  policy_id     = vastdata_view_policy.this[each.key].id
  tenant_id     = vastdata_tenant.this[each.key].id
  qos_policy_id = vastdata_qos_policy.this[each.key].id
  protocols     = ["NFS"]
  create_dir    = true
}
