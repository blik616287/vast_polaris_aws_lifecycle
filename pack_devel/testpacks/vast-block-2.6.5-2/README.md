# VAST CSI Block Driver (NVMe/TCP) — `vast-block`

Block PersistentVolumes from VAST over **NVMe/TCP**. Wraps the upstream `vastblock` **2.6.5** chart (`https://vast-data.github.io/vast-csi`). Provisioner id `csi.vastdata.com`.

Maps to the Control-Plane **Phase 3 "Managed NVMe/TCP Block storage"** capability. Block volumes are generally `ReadWriteOnce` (for RWX shared filesystems use `vast-csi` instead).

## Prerequisites
- Worker nodes need the **NVMe/TCP** kernel modules (`nvme-tcp`) and `nvme-cli`; they must reach the VAST VIP pool on the NVMe/TCP port (confirm exact port with VAST — firewall doc lists 4420/4520 as "SPDK Target").
- Credentials secret (`vast-mgmt`) — same as `vast-csi` (see that README).
- Privileged pods for the node plugin — the `vast-block` namespace is labelled `privileged`.

## Configure
| Field | Purpose |
|---|---|
| `charts.vastblock.endpoint` / `secretName` | VMS endpoint + creds |
| `charts.vastblock.storageClassDefaults.vipPool` | data VIP pool |
| `charts.vastblock.storageClassDefaults.fsType` | `ext4`/`xfs`, or empty for raw block |
| `charts.vastblock.blockHostsAutoPrune` | clean up stale NQNs for ephemeral nodes |

```yaml
charts:
  vastblock:
    storageClasses:
      vastdata-block:
        vipPool: <tenant-vip-pool>
        fsType: ext4
```
