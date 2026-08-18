# VAST tenant storage verification kit

Self-contained manifests to **independently verify NFS, COSI/S3, and NVMe/TCP
block** storage against each VAST tenant, on your own schedule. Each manifest
provisions a volume/bucket, writes a unique token, reads it back, and prints a
`… VERIFY: PASS` line. No external tooling — everything runs as a Kubernetes Job.

## What gets tested

| # | Protocol | Driver | StorageClass / API | Manifest |
|---|---|---|---|---|
| 1 | NFS filesystem (RWX) | `csi.vastdata.com` | `vastdata-filesystem` | `01-nfs.yaml` |
| 2 | NVMe/TCP block (RWO) | `block.csi.vastdata.com` | `vastdata-block` | `02-nvme-tcp-block.yaml` |
| 3 | COSI / S3 object | `csi.vastdata.com` (COSI) | `objectstorage.k8s.io` | `03-cosi-s3.yaml` |

## Tenants / clusters

Each tenant is its own Palette cluster in the ISC-Strategic-Alliance project.
Point `kubectl` at the tenant you want to test, then apply the manifests.

| Tenant | Cluster | VPC / cluster CIDR | VAST tenant view |
|---|---|---|---|
| tenant-1 | `voc-tenant-1` | 10.40.0.0/16 | `/tenant-1`, pool `tenant-1-pool` |
| tenant-2 | `voc-tenant-2` | 10.50.0.0/16 | `/tenant-2`, pool `tenant-2-pool` |

Get a cluster's kubeconfig from the Palette console (Cluster → **Kubeconfig**), or
via API. Then `export KUBECONFIG=<downloaded file>` and confirm you're on the
right cluster:

```bash
kubectl get nodes            # both clusters are 2-node (1 control-plane + 1 worker)
kubectl get storageclass     # expect vastdata-filesystem + vastdata-block
kubectl get bucketclass      # COSI CRDs present
```

## Running a check

NFS and block are **automatically tenant-scoped** (the driver on each cluster is
wired to that tenant), so `01` and `02` apply with **no edits**:

```bash
kubectl apply -f 01-nfs.yaml
kubectl wait --for=condition=complete job/verify-nfs --timeout=180s
kubectl logs job/verify-nfs          # -> "NFS VERIFY: PASS"
kubectl delete -f 01-nfs.yaml        # clean up (and to re-run)
```

Same pattern for `02-nvme-tcp-block.yaml` (`job/verify-block`).

**COSI needs 3 values edited per tenant** (buckets aren't auto-scoped — the
BucketClass must name the tenant's S3 view policy / pool / path). Edit the top of
`03-cosi-s3.yaml`:

| Cluster | `view_policy` | `vip_pool_name` | `root_export` |
|---|---|---|---|
| voc-tenant-1 | `tenant-1-s3-policy` | `tenant-1-pool` | `/tenant-1` |
| voc-tenant-2 | `tenant-2-s3-policy` | `tenant-2-pool` | `/tenant-2` |

```bash
kubectl apply -f 03-cosi-s3.yaml
kubectl wait --for=condition=complete job/verify-cosi --timeout=300s
kubectl logs job/verify-cosi         # -> "COSI/S3 VERIFY: PASS"
kubectl delete -f 03-cosi-s3.yaml
```

## Notes

- **Isolation:** each cluster can only reach its own tenant's view/pool over the
  peered VPC. A bucket/volume created here lives in that VAST tenant only.
- **NFS StorageClass fix:** the `vastdata-filesystem` SC on each cluster was
  recreated with `view_policy=<tenant>-policy` (stock value `default` provisions
  PVs in the ROOT tenant, so a mount over the tenant VIP fails with
  `No such file or directory`). This should be codified in the vast-csi pack
  values (`view_policy` → a per-tenant profile var) so it survives a redeploy —
  same pattern as the COSI `view_policy` fix.
- **COSI driver requirement:** working COSI/S3 multitenancy depends on the
  patched vast-cosi driver image (stock `vastdataorg/csi:v2.6.5` mis-scopes the
  S3 access key). If `verify-cosi` fails with `InvalidAccessKeyId`, the cluster is
  running the stock driver — see the `vast-cosi-multitenancy` runbook.
- **Re-running:** Jobs use fixed names; `kubectl delete -f <file>` then re-apply.
- **If a pod is stuck `ContainerCreating`:** for COSI the pod waits for the
  `verify-cosi-creds` secret — check `kubectl describe bucketaccess verify-access`
  (accessGranted should be `true`). For block, check the node has `nvme-tcp`.

## NVMe/TCP node hygiene — the orphan-reaper

**Why block mounts can crawl or hang.** Every block PVC opens an NVMe/TCP session
(controller) from the node to the VAST block target. A *graceful* pod delete runs
`NodeUnstageVolume` → `nvme disconnect`. An **ungraceful** removal —
`kubectl delete pod --force --grace-period=0`, a kubelet/node crash, or an OOM-kill —
leaves the session **orphaned** (still connected, but its backing VAST namespace is
gone). Orphans loop forever in kernel NVMe error-recovery, and that thrash wedges
`blkid`/udev in uninterruptible **D-state** on *every* new block device, so fresh
mounts crawl for minutes. Signature: `NodeStageVolume … ('Process did not terminate
within 10 seconds', ['/usr/sbin/blkid', '/dev/nvmeXnY', …])`, pod stuck `ContainerCreating`.

**Prevention, in order:**
1. **Never `kubectl delete pod --force --grace-period=0` on a pod with a volume.**
   It skips `NodeUnstageVolume` — the #1 trigger. Always graceful-delete.
2. **Deploy the orphan-reaper** (durable, self-healing) — a privileged DaemonSet that
   every 120s disconnects TCP controllers with zero namespaces (two-strike, so it
   never touches a live or mid-connect volume):
   ```bash
   kubectl apply -f ../ops/nvme-tcp-reaper.yaml     # once per VAST-block cluster
   ```
3. **Preflight reap** before a demo/benchmark (belt-and-suspenders, or for clusters
   without the DaemonSet) — one-shot across all nodes:
   ```bash
   ../ops/preflight-reap.sh <kubeconfig>
   ```

**Recovering an ALREADY-wedged node:** once `blkid` is in D-state, even sysfs
`delete_controller` can hang — the reliable reset is an EC2 reboot of that node
(clears all NVMe sessions + D-state). The reaper's job is to prevent ever getting
there. *Measured: a poisoned node took block mounts from ~9s to 4+ minutes; after
reaping, back to ~9s.*
