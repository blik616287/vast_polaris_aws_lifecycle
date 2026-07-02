# VAST CSI Driver (NFS) — `vast-csi`

Dynamic provisioning of `ReadWriteMany` NFS PersistentVolumes from a [VAST Data](https://vastdata.com) cluster (on-prem or VAST on Cloud / VoC on AWS). Each PV is a VAST **view** (directory + quota); provisioner id `csi.vastdata.com`.

Wraps the upstream Helm chart `vastcsi` **2.6.5** (`https://vast-data.github.io/vast-csi`).

## Prerequisites

- A reachable VAST cluster: the **CSI controller** must reach the **VMS REST API** (TCP **443**); **every worker node** must reach the **VIP pool** (NFS **2049**, plus **111**/**20048** for NFSv3). On AWS, ensure security groups + routing allow this and the VAST **view policy / tenant Client IP Range** includes the worker-node subnet CIDRs.
- A **credentials secret** (not shipped in the pack):
  ```bash
  kubectl create namespace vast-csi
  kubectl -n vast-csi create secret generic vast-mgmt \
    --from-literal=username='<VAST user>' \
    --from-literal=password='<VAST password>' \
    --from-literal=endpoint='https://<VMS-VIP>'
  # or token auth (VAST 5.3+): --from-literal=token='<API token>'
  ```
- **Privileged pods**: the CSI node DaemonSet runs privileged. If Pod Security Admission / Kyverno / OPA is enforced, whitelist the `vast-csi` namespace (the pack sets the PSA `privileged` label via `pack.namespaceLabels`).
- **Snapshots/clones** (optional): install the external-snapshotter CRDs (v6.0.1+) once per cluster.

## Configure

Set in the cluster-profile layer's `values.yaml` (override per cluster/tenant — no pack rebuild needed):

| Field | Purpose |
|---|---|
| `charts.vastcsi.endpoint` | VMS REST endpoint `https://<VMS-VIP>` |
| `charts.vastcsi.secretName` | credentials secret name (`vast-mgmt`) |
| `charts.vastcsi.storageClassDefaults.vipPool` / `vipPoolFQDN` | data VIP pool the nodes mount from |
| `charts.vastcsi.storageClassDefaults.storagePath` | base path on VAST for created views |
| `charts.vastcsi.storageClassDefaults.viewPolicy` | VAST view policy (access control) |
| `charts.vastcsi.storageClassDefaults.qosPolicy` | optional QoS policy attached to views |
| `charts.vastcsi.storageClasses.<name>` | one entry per StorageClass to create |

### Cloud (AWS / VoC) tuning
The AWS data path is **TCP only** (EFA cannot carry NFSoRDMA). For throughput: `vipPoolFQDNRandomPrefix: true` (spreads mounts across CNodes), `mountOptions` with `nconnect=16,proto=tcp`, and place worker nodes in the **same AZ** as the VIP pool on 100 Gbps-class instances.

## Multi-tenancy (Phase 2 mapping)
Map a Palette **Project/Workspace** to a dedicated VAST **tenant → VIP pool → QoS policy**, then expose it as a per-tenant StorageClass:
```yaml
charts:
  vastcsi:
    storageClasses:
      tenant-a-fs:
        vipPool: tenant-a-pool
        storagePath: /k8s/tenant-a
        viewPolicy: tenant-a-policy
        qosPolicy: gold
```
Provision the VAST-side tenant/VIP/QoS with the `vast-data/vastdata` Terraform provider (see `terraform/` in the engagement repo) and cap consumption with a Palette Workspace storage `ResourceQuota` (Spectro RBAC pack ≥1.0.1).

## Validate
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vast-test, namespace: vast-csi}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: <your-storageclass>
  resources: {requests: {storage: 5Gi}}
EOF
kubectl -n vast-csi get pvc vast-test   # expect Bound
```

## Siblings
- `vast-block` — block volumes over NVMe/TCP (`vastblock` chart)
- `vast-cosi` — S3 buckets via COSI (`vastcosi` chart)
