# S3 Access-Key Handling (VAST COSI / Object Storage)

**How per-tenant S3 access keys are created, scoped, and stored in the VAST × Palette integration — and the driver fix required to make it work.**

> **TL;DR** — We don't pre-provision or store S3 keys anywhere in our automation. Keys are minted **per-workload at runtime by the COSI driver**, **tenant-scoped**, and land only in the consuming pod's credentials secret. The one non-obvious part is *tenant scoping* — which is where we found and fixed a driver issue in `vastdataorg/csi:v2.6.5`.

---

## The model

NFS and block "just work" for us because the tenant is implied by the view path. **S3 is different:** the S3 *user is global* across the cluster, but the *access key is per-tenant* — a request maps to whatever tenant the key was created in. A key created in the default tenant, used against a tenant-scoped bucket VIP, returns **`InvalidAccessKeyId`**.

So we anchor everything to tenant identity in two places:

1. **A per-tenant S3-Native view policy** — `<tenant>-s3-policy`, `flavor: S3_NATIVE`, bound to `tenant_id`. Our lifecycle automation (the CodeBuild `tenant` action) creates it alongside the tenant. The COSI `BucketClass.view_policy` points at it, so the bucket lands in that tenant. Names are unique per tenant because the driver resolves the policy by name as cluster-admin (which sees all tenants), so a shared name would be ambiguous.
2. **The access key created in that same tenant's context** — the part that has to be right, and where the stock driver fell short.

---

## What we found in the driver (`vast-csi` v2.6.5)

- `plugins/cosi.py :: DriverGrantBucketAccess` parses the bucket id (`name@<tenant>@endpoint`) but **discards the tenant**.
- `vms_session.py :: generate_access_key` posts to `/users/{id}/access_keys/` with **no body** — so the key is always created in the **default** tenant.

Functionally the bucket is isolated, but the key can't authenticate against the tenant's VIP → `InvalidAccessKeyId`.

### The RBAC wall behind it

We confirmed *why* this isn't trivial:

- **Super-admin** can't tenant-scope the call (`X-Tenant-Name` → 401 / `NoneType`).
- A **tenant-admin** can create the key but **cannot** create the global user (403 — a cluster-only operation).
- The path that works: **cluster-admin passing `tenant_id` in the `POST /users/{id}/access_keys/` body.** The key then authenticates on the tenant VIP. Verified end-to-end.

---

## The fix

Two lines — keep the parsed tenant and pass it through:

```python
# plugins/cosi.py — keep the tenant instead of discarding it, then:
vms_session.generate_access_key(user.id, tenant_id=tenant_id)

# vms_session.py — include it in the request body:
#   POST /users/{id}/access_keys/   →   {"tenant_id": int(tenant_id)}
```

We run a driver image built from `vastdataorg/csi:v2.6.5` with that change on the **`csiVastPlugin`** container — the only container that runs its own image (the COSI sidecars are build-on-deploy, crane-exported onto a 0-CVE base). Swapping that one image is sufficient.

**Result, validated on two isolated tenant clusters:** `BucketClaim → bucketReady`, `BucketAccess → tenant-scoped key`, and S3 `PUT` / `LIST` / `GET` succeed on the tenant VIP.

---

## Security posture

- The driver authenticates to VMS with a **cluster-admin** credential, sourced from a Kubernetes secret (no tenant field).
- Access keys are **ephemeral and per-`BucketAccess`** — created on demand, written **only** into the requesting workload's `credentialsSecretName` secret, and revoked when the `BucketAccess` is deleted.
- We **never** generate, cache, or store S3 keys in the CodeBuild / Terraform automation. That layer only establishes the tenant and the S3-Native view policy; all key material lives in-cluster, per workload.
- Keys are tenant-scoped, so cross-tenant access is blocked at the VAST layer, not just at the application.

---

## Division of responsibility

| Stage | Actor | Produces |
|---|---|---|
| `tenant` build (CodeBuild) | `scripts/tenant-voc.sh` → VMS REST | tenant + **S3-Native view policy** (scoping anchor only) |
| `BucketClaim` (runtime) | COSI driver (`csiVastPlugin`) | bucket, placed in the tenant via the policy's `tenant_id` |
| `BucketAccess` (runtime) | COSI driver (`csiVastPlugin`) | **tenant-scoped access key** → workload credentials secret |

---

## Ask back to VAST

We'd like the two-line tenant-scoping fix **upstreamed into the COSI driver** so per-tenant S3 works out of the box on stock `vastdataorg/csi`. Happy to send the diff.

---

*Related: `tenant-verification/README.md` (COSI driver requirement note), `scripts/tenant-voc.sh` (S3-Native policy creation), and the `vast-cosi-multitenancy` runbook.*
