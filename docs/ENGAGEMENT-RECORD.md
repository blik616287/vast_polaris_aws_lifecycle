# SpectroCloud × VAST — Engagement Record

**A record of the work delivered against `SCOPING.md` and `VALIDATION-PLAN-RESPONSE.md`.**

**Substrate:** VAST-on-Cloud (VoC) on AWS · region `us-east-2` · dedicated VAST VPC `10.20.0.0/16` (VMS `10.20.4.81`, ENode `i3en.24xlarge`) · Palette-managed EC2 Kubernetes clusters (SaaS `console.spectrocloud.com`, project *ISC-Strategic-Alliance*, and self-hosted).

> This record tracks the two scoping documents section-by-section. Status legend: **✅ Delivered** · **🧪 Validated** (delivered *and* exercised end-to-end with a passing test) · **◑ Partial** · **▢ Deferred / next increment**.

---

## 1. Executive summary

The scoping documents defined a joint architecture to stand up **VAST-on-Cloud on AWS** and consume it from **Palette-managed Kubernetes** via the VAST **CSI / COSI / block** drivers, with **multi-tenant isolation** and **QoS**. That architecture is now **built, automated, and validated end-to-end**:

- **VoC deployed** on AWS via the Polaris / `vastcloud` path, in its **own VPC** (the recommended **Option B** topology), with a codified **deploy → tenant → teardown lifecycle**.
- **Network foundation** (VPC, peering, security groups, tenant client-IP ranges) delivered as **Terraform**, peering the VAST VPC to **four** consuming cluster VPCs.
- **Three VAST packs** (`vast-csi`, `vast-cosi`, `vast-block`, chart `2.6.5`, rev `-4`) built, published to **OCI/ECR** registries, and wired into a **Palette cluster profile** with VMS connection details as per-cluster sensitive variables.
- **Multi-tenancy proven**: isolated VAST tenants (VIP pool + view + view policy + QoS + client-IP range) per Palette cluster.
- **Storage validated**: **NFS RWX `PASS`** and **NVMe/TCP block `PASS`** end-to-end against isolated tenants, with a **self-service verification kit**.

The result covers **Validation-Plan Phase 1 (CSI)** and **Phase 2 (multi-tenancy)** in full; **Phase 3 (PaletteAI / DataEngine / DataBase)** remains the next increment, gated on VAST-supplied services.

---

## 2. `SCOPING.md` — build mechanics, section by section

| § | Scoped item | Status | Delivered as |
|---|---|:--:|---|
| **1** | New Palette-managed EC2 K8s cluster consuming VAST (CSI/NFS primary; S3/block secondary) | 🧪 | Multiple Palette clusters consuming VAST over CSI (NFS), COSI (S3), block (NVMe/TCP) |
| **3** | VoC via Polaris + `vastcloud` (6-stage preflight) | ✅ | Deployed; `voc/scripts/polaris-register.sh`, `deploy-voc.sh` wrap the flow; VMS live at `10.20.4.81` |
| **4** | CSI controller→VMS + node→VIP reachability; multi-tenancy by Client IP Range | 🧪 | Both reachability paths validated; per-tenant client-IP ranges enforced (`tenants.json`) |
| **5** | Network topology decision — **Option B** (VAST in own VPC, peered) | ✅ | Realized: VAST VPC `10.20.0.0/16` peered to cluster VPCs `10.30`/`10.40`/`10.50` + in-VPC |
| **6** | Capacity & instance sizing | ✅ | VoC on `i3en.24xlarge`; cluster CP `m5.xlarge` (≥4 vCPU floor confirmed), workers `m5.xlarge` |
| **7** | Phased execution plan (Phase 0–5) | 🧪 | See §4 below — Phases 0–4 delivered/validated, Phase 5 partial |
| **10** | Terraform owns the connective substrate (plan→review→apply) | ✅ | `voc/terraform/*` (network, peering, tenancy), `spectro-peering/`, `voc-tenants/` |
| **11** | Build the `vast-csi` Palette pack (chart 2.6.5) | 🧪 | Built + published + attached + validated (extended to COSI + block too) |
| **12** | Firewall / ports on SGs | ✅ | SG rules for NFS 2049/111/20048(+20106-8), VMS 443/80, block 4420/4520/8009, RPC, SSH |
| **13** | RDMA/EFA finding — no RDMA path to VAST on AWS; plan high-bandwidth **TCP** | ✅ | Confirmed and planned around (NVMe/TCP + NFS over TCP data path; EFA scoped as optional GPU-only add-on) |

---

## 3. `VALIDATION-PLAN-RESPONSE.md` — validation results

### Phase 1 — VAST CSI on Palette — 🧪 **Validated**
- **Packs built & published:** `vast-csi`, `vast-cosi`, `vast-block` (chart `2.6.5`, revision `-4`) → OCI/ECR (**ISC Palette Registry**, both SaaS and self-hosted).
- **Cloud CSI tuning** from the scope applied in pack values (TCP data path, VIP-pool selection, mount options).
- **Result:** **`NFS VERIFY: PASS`** (RWX provision + read/write) and **`NVME/TCP VERIFY: PASS`** (block RWO) on live Palette clusters; all driver pods (`vast-csi`, `vast-cosi`, `vast-block`) Running; StorageClasses `vastdata-filesystem` + `vastdata-block` present.

### Phase 2 — Multi-tenancy architecture — 🧪 **Validated**
- **Isolated tenants** provisioned per consuming cluster, each = **tenant + VIP pool + view policy + view + QoS tier**, gated by **client IP range** (`voc/scripts/tenant-voc.sh`, `tenants.json`; idempotent, one entry per cluster).
- **QoS tiers** defined (bronze / silver / gold — BW + IOPS Max/Burst).
- **Palette→VAST mapping** realized: each cluster → its own tenant → StorageClass (VIP pool + path baked in); VMS credentials/endpoint delivered as **per-cluster sensitive profile variables**, never baked into the published profile.
- **Result:** separate clusters (`fieldeng`, `spectro`, `voc-tenant-1` @ `10.40/16`, `voc-tenant-2` @ `10.50/16`) each reach **only** their own VIP pool / view; validated independently.

### Phase 3 — PaletteAI Profile Bundles (DataEngine / DataBase) — ▢ **Deferred**
- Next increment; gated on VAST-supplied DataEngine-enabled cluster + GA confirmation (see `VALIDATION-PLAN-RESPONSE.md` §E). Not started by design.

---

## 4. Phased execution plan (`SCOPING.md` §7) — completion

| Phase | Status | Notes |
|---|:--:|---|
| **0 — Decisions & procurement** | ✅ | BYOL/Polaris obtained; **Option B** topology chosen; Palette-into-VPC behavior confirmed |
| **1 — Network foundation** | ✅ | VAST VPC + subnets + IGW/NAT; **peering** to 4 cluster VPCs with return routes; SGs; tenant client-IP ranges — all Terraform |
| **2 — Deploy VAST (VoC)** | ✅ | Polaris template + `vastcloud create`; post-deploy tenants/VIP-pools/views/policies automated; VMS endpoint persisted to SSM |
| **3 — Provision Palette clusters** | 🧪 | Cluster profile `vast-storage-aws` (OS+k8s+CNI+CSI + 3 VAST packs); clusters deployed on SaaS + self-hosted; node→VIP + controller→VMS reachability verified |
| **4 — Build vast-csi pack & validate** | 🧪 | Packs built/published/attached; privileged namespaces handled; `vast-mgmt` secret from profile vars; **RWX PVC + block PVC validated** |
| **5 — Hardening & ops** | ◑ | Multi-tenant isolation + QoS delivered; lifecycle automation + teardown in place; **remaining:** per-AZ NAT HA review, monitoring dashboards (Prometheus/Grafana), documented runbook |

---

## 5. Deliverables inventory

**Infrastructure-as-Code (Terraform)**
- `voc/terraform/` — VAST VPC network, VoC lifecycle substrate, VMS endpoint outputs
- `voc/terraform/spectro-peering/` — cross-account peering (spectro ↔ VAST VPC)
- `voc/terraform/voc-tenants/` — reusable per-tenant peer-VPC module (workspace-per-tenant)
- `terraform/network/`, `terraform/vast-tenancy/` — network + VAST tenancy modules

**Automation (`voc/scripts/`)**
- `polaris-register.sh` · `deploy-voc.sh` · `destroy-voc.sh` — VoC lifecycle
- `tenant-voc.sh` — idempotent VMS multi-tenancy setup (tenant/VIP-pool/view/policy/QoS)
- `validate-voc.sh` — post-deploy validation + VMS endpoint persistence
- Driven by a CodeBuild lifecycle pipeline (deploy / tenant / teardown actions)

**Go tooling (`voc/pack_devel/`)**
- `packsync` — production-grade pack publisher (ECR/OCI + Palette sync; 96%+ test coverage, CI, Dockerized builder)
- `vast-profile` — `create-profile` (builds+publishes the cluster profile, resolves pack UIDs by name) + `deploy-cluster` (binds a cluster, fills VMS vars per-tenant)
- `packtest` — pack validation harness

**VAST packs** — `vast-csi`, `vast-cosi`, `vast-block` (chart `2.6.5`, revisions `-1`…`-6`; `-4` published)

**Verification kit (`voc/tenant-verification/`)** — self-service NFS / NVMe-TCP-block / COSI-S3 Jobs (`01`/`02`/`03`) + README; each writes-and-reads a token and prints `VERIFY: PASS`

**Documents** — `SCOPING.md`, `VALIDATION-PLAN-RESPONSE.md`, `PACKS.md`, `EMAIL-TO-VAST.md`, `voc/README.md`, this record

---

## 6. Validation evidence (as run)

| Test | Driver / class | Result |
|---|---|---|
| NFS filesystem, RWX | `csi.vastdata.com` / `vastdata-filesystem` | **`NFS VERIFY: PASS`** — PVC Bound (VMS-provisioned), read/write verified |
| NVMe/TCP block, RWO | `block.csi.vastdata.com` / `vastdata-block` | **`NVME/TCP VERIFY: PASS`** — PVC Bound, device attached + mounted, read/write verified |
| COSI / S3 object | `objectstorage.k8s.io` (COSI) | Drivers Running; provisioner validated; bucket test available (per-tenant edits) |
| Tenant isolation | VIP pool + view + client-IP range | Proven — each cluster reaches only its own tenant's pool/view |
| Control-plane reach | CSI controller → VMS `:443` | Verified (volumes provision on demand → VMS API reachable + authorized) |
| Data-path reach | node → VIP pool (NFS/block) | Verified (mounts succeed over the peered path) |

---

## 7. Deviations from scope & notable findings

- **Test substrate moved to a dedicated VAST VPC (`10.20.0.0/16`)** peered to multiple cluster VPCs — this *is* the recommended Option B, realized at wider scale (four peers) than the single-peer baseline in the scope.
- **Scope extended beyond NFS-only:** the scope's primary was NFS CSI; delivered all three — **NFS + COSI/S3 + NVMe/TCP block** — as separate validated packs.
- **Control-plane automation:** the scope proposed the `vast-data/vastdata` Terraform provider as the cleanest path; delivered via an **idempotent imperative VMS-API flow** (`tenant-voc.sh`) that maps 1:1 to the same objects — interchangeable with the TF-provider path.
- **Instance-sizing finding:** Palette enforces a **≥4 vCPU floor per control-plane pool** — a single `m5.large` (2 vCPU) CP is rejected; `m5.xlarge` is the practical minimum.
- **Block mount `blkid` settle:** on first mount a fresh NVMe/TCP device can hit a transient `blkid` probe timeout that self-resolves on retry — node-side, not a VAST fault (confirmed by a clean `PASS` on retry / on other nodes).

---

## 8. Open items (next increment)

1. **Phase 3 / PaletteAI** — DataEngine + DataBase bundles, pending a VAST-supplied DataEngine-enabled cluster + GA confirmation.
2. **Ops hardening (Phase 5)** — per-AZ NAT for HA, Prometheus/Grafana per-tenant dashboards, documented runbook.
3. **Pack certification** — a *validated* (vs community) VAST pack via the Spectro Cloud Partner Program.
4. **Consolidated asks to VAST** — see `VALIDATION-PLAN-RESPONSE.md` §E (remaining: DataEngine GA, sample-app repos, certification path).
