# Feed these into the per-tenant vast-csi StorageClass (pack values).
output "tenant_storageclass_inputs" {
  description = "Per Palette tenant: the values to set on its vast-csi StorageClass."
  value = {
    for k, v in var.tenants : k => {
      vip_pool     = vastdata_vip_pool.this[k].name
      view_policy  = vastdata_view_policy.this[k].name
      qos_policy   = vastdata_qos_policy.this[k].name
      storage_path = v.storage_path
      tenant_id    = vastdata_tenant.this[k].id
    }
  }
}
