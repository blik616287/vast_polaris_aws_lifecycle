# VAST COSI Driver (S3) — `vast-cosi`

S3 bucket provisioning for Kubernetes via the **Container Object Storage Interface (COSI)**, backed by VAST. Wraps the upstream `vastcosi` **2.6.5** chart (`https://vast-data.github.io/vast-csi`). Driver id `csi.vastdata.com`.

Maps to the Control-Plane **Phase 1 "Object Storage (S3) — bucket provisioning / access key management"** capability (delivered through K8s COSI rather than direct VMS calls).

## Prerequisites
- COSI is consumed via `BucketClass` / `BucketClaim` / `BucketAccess` objects — the COSI CRDs + controller must be present in the cluster (ship the upstream COSI controller as a dependency layer if not already installed).
- Credentials secret (`vast-mgmt`) — same as `vast-csi`.
- Worker/controller reachability to the VMS REST API and to the S3 VIP endpoint (HTTP 80 / HTTPS 443).

## Configure
| Field | Purpose |
|---|---|
| `charts.vastcosi.endpoint` / `secretName` | VMS endpoint + creds |
| `charts.vastcosi.bucketClassDefaults.vipPool` | VIP pool buckets are served from |
| `charts.vastcosi.bucketClassDefaults.s3Policy` | S3 policy applied to created buckets |
| `charts.vastcosi.bucketClasses.<name>` | one entry per BucketClass |

```yaml
charts:
  vastcosi:
    bucketClasses:
      vastdata-bucket:
        vipPool: <tenant-vip-pool>
        s3Policy: <tenant-s3-policy>
```
