# SpectroCloud × VAST — Validation Plan Response & Joint Architecture

Companion to `SCOPING.md` (which covers the AWS/EC2/Palette/VAST build mechanics). This doc answers the Validation Plan's questions, reconciles the two phase tracks, populates the capability matrix, and defines the control-plane automation architecture.

**Test substrate:** VAST on Cloud (VoC) on AWS in the existing Spectro account `216938125181` / us-east-2; new EC2 K8s cluster provisioned by Palette. No hardware required for Phases 1–2.

---

## A. Reconciling the two "phase" tracks

There are **two different phase numberings** in the source docs — they are not the same axis:

| | Validation Plan (engineering/validation track) | Control-Plane doc (go-to-market/monetization track) |
|---|---|---|
| **P1** | VAST CSI pack on Palette (PVCs, snapshots, clones) | **Monetize Storage** — multi-tenant S3/NFS, CSI, monitoring, data protection |
| **P2** | Multi-tenancy architecture (Palette Workspaces/Projects → VIP pools + QoS) | **Monetize Data + Inference** — Managed DB, Vector DB, Event Broker, KV-cache, identity federation |
| **P3** | PaletteAI Profile Bundles for VAST data pipelines (DataEngine/DataBase) | **Monetize Enterprise Performance** — NVMe/TCP block, multi-region DR, BYOK, SLA tiers |

**How they map:** Validation **P1 + P2 together deliver Control-Plane Phase 1** (the storage backbone + tenancy/QoS that makes "Monetize Storage" real). Validation **P3 delivers Control-Plane Phase 2** (managed data services + inference). **Control-Plane Phase 3** (NVMe/TCP block, DR, BYOK, SLA) has **no Validation-Plan counterpart yet** — it's the next increment after the three validation phases.

**Recommendation:** drive execution by the **Validation Plan** numbering (it's the concrete build order); use the Control-Plane phases as the **monetization/marketing framing** layered on top. One roadmap, two lenses.

---

## B. Answers to the Validation Plan questions

### Phase 1 — VAST CSI on Palette

**Q1. Can we validate on VAST DataSpace on AWS / VAST Cloud, no hardware?**
**Yes — this is the recommended path.** The deployable test target is **VAST on Cloud (VoC)**: a full VAST cluster running on EC2, deployed via VAST's **Polaris portal + `vastcloud` CLI** (6-stage preflight gate). *Terminology nuance:* **DataSpace** is VAST's global-namespace/replication feature; the thing you actually stand up to test against is **VoC / VAST Cloud**. The **CSI driver and its API surface are identical to on-prem**, so everything validated on VoC (provisioning, snapshots, cloning, QoS) transfers to hardware later. ⚠️ A real VoC endpoint, tenant, VIP pool, and S3 keys must be **provisioned by VAST** (BYOL + Polaris invite) — see §E.

**Q2. Cloud vs on-prem CSI tuning?**
Yes — the key difference is **the AWS data path is TCP-only** (EFA cannot carry NFSoRDMA; see `SCOPING.md` §13), whereas on-prem uses NFSoRDMA/RoCE. Recommended cloud tuning:
- **Spread mounts across CNodes:** StorageClass `vip_pool_fqdn_random_prefix: "true"` + `lb_strategy: roundrobin` (or `vipPoolFQDN` with random prefix).
- **Parallel TCP per mount:** NFS `nconnect=8..16` in `mountOptions` (e.g. `vers=3,proto=tcp,nolock,nconnect=16`; NFSv4.1 also fine).
- **Placement:** worker nodes in the **same AZ** as the VIP pool (latency + avoids cross-AZ $).
- **Instance bandwidth:** 100 Gbps-class nodes (`i4i`, `i3en`, `c6in`, `c7gn`, `p4d/p5`) for throughput-bound AI I/O.
- **Multiple StorageClasses / VIP pools** for parallelism and per-tenant separation.
- On-prem only: RDMA mount options + RoCE fabric — not applicable in AWS.

### Phase 2 — Multi-Tenancy Architecture

**Q1. How to set up a test env to validate VIP Pool + QoS isolation under heavy simulated AI load?**
- **Provision ≥2 tenants**, each = `vastdata_tenant` + dedicated `vastdata_vip_pool` (tenant-bound, optionally VLAN-tagged) + a `vastdata_qos_policy` tier (e.g. Bronze/Silver/Gold via static Max+Burst BW/IOPS), attached to each tenant's views via `qos_policy_id`. In Palette, map each to a **Project/Workspace → namespace → dedicated StorageClass** (VIP pool + QoS baked into SC params) + a **storage `ResourceQuota`** (needs Spectro RBAC pack ≥1.0.1).
- **Load generators:** `fio`, `vdbench`, `elbencho`, or **MLPerf Storage** (the AI-storage benchmark) running as K8s Jobs in each tenant namespace simultaneously.
- **Validate isolation (noisy-neighbor test):** drive Tenant A to saturation, confirm Tenant B holds its guaranteed Max BW/IOPS. Confirm network isolation by verifying each tenant only reaches its own VIP pool (Client IP Range enforcement). Capture per-tenant capacity/IOPS/latency from VAST metrics → Prometheus/Grafana (this also exercises the monitoring matrix rows).

**Q2. Does the VMS REST API support fully automated VIP Pool + QoS provisioning, triggerable dynamically from Palette?**
**Yes — fully, and there's more than one mechanism:**
- **VMS REST API** — standard CRUD at `https://<VMS-VIP>/api` (live Swagger at `/api`); auth via **API token (VAST 5.3+)** or basic; scope automation to a limited **"manager" RBAC user**, not root. `/api/quotas/` is doc-confirmed; `vippools`/`qospolicies`/`views`/`tenants` follow the same uniform collection model.
- **Official Terraform provider `vast-data/vastdata` (v3.2.2, GA-grade, 46 resources)** — `vastdata_tenant`, `vastdata_vip_pool`, `vastdata_qos_policy`, `vastdata_view`, `vastdata_view_policy`, `vastdata_quota`, `vastdata_user`/`_user_key`, `vastdata_s3_policy`, `vastdata_api_token`, RBAC, replication/snapshots. **This is the cleanest automation path.**
- **`vastpy`** — official schema-less Python SDK for VMS (good for an operator/controller).
- **QoS model:** limits **BW (MB/s) and/or IOPS**, three-tier **Max / Burst / Credit**, scoped **per view / bucket / tenant / user**, plus **capacity-based QoS** (perf-per-GB) for SLA tiering. `policy_type` = `VIEW` or `USER`.

→ See **§D** for how Palette actually triggers this.

### Phase 3 — PaletteAI Profile Bundles (DataEngine / DataBase)

**Q1. What components/operators/credentials to test DataEngine + DataBase?**
*Self-serve software:*
- **VAST DB:** `pip install vastdb` (PyArrow-based SDK) + `vastdb-adbc-driver`; `vastpy` for mgmt.
- **Trino:** official **`vastdataorg/trino-vast`** image (Docker Hub) + a `vast.properties` catalog Secret; pair with the community **`trinodb/trino`** Helm chart. (Or BYO Trino + the `trino-vast-*.zip` plugin from `vast-db-connectors`.)
- **Spark:** `spark3-vast-*.jar` from `vast-db-connectors` releases, injected into a Spark image; deploy via **`kubeflow/spark-operator`** Helm chart. (No official VAST Spark image/chart — assemble it.)
- **DataEngine:** the **`dataengine-cli`** binary is a *client* (functions/triggers/pipelines run inside VAST on CNodes, not on your K8s) — bake it into a tooling image.
*Credentials (VAST-supplied):* VIP-pool DNS endpoint, S3 access/secret keys, a provisioned bucket/schema; for DataEngine also VMS endpoint + user/pass + tenant + container-registry access.
- **Connection params:** `endpoint` (VIP-pool DNS, port 80/443 — **not 9090**; 9090 is Prometheus, Trino UI is 8080), optional `data_endpoints` (VIP list for LB), `access_key_id`/`secret_access_key`, `region`, `bucket`/`schema`/`table`.

**Q2. Test environments for DataEngine and DataBase?** — **VAST-supplied (route to VAST).** DataBase is GA; **DataEngine is maturing/preview-grade** (field-docs still a stub, CLI is dev-tagged `v5.5.0-dev`). Confirm a DataEngine-enabled VoC cluster + GA status with VAST before committing P3 timelines.

**Q3. Sample pipelines / reference workloads?** — Public, self-serve: **`vast-data/dataengine-pipelines`** (DataEngine examples), **`vast-data/cosmos-labs`** (vastpy+vastdb labs incl. a weather data pipeline), **`vastdb_sdk`** in-repo examples, and the **`data-platform-field-docs`** site (Trino/Spark/SDK how-tos). The canonical DataEngine demo to replicate: object upload → event trigger → Python resize/inference function → write back to DataStore + DataBase. ⚠️ Marketing sample apps ("Video Search & Summary", "Document Research Assistant") — exact repos to be confirmed with VAST.

---

## C. Capability matrix (proposed fill)

Legend: **✅** native/available · **◑** partial / needs integration work · **▢** future increment. **VoC** = available today in base VAST-on-Cloud; **P1/P2/P3** = the *Validation-Plan* phase where the joint Palette integration delivers/surfaces it.

| Domain | Capability | VoC | P1 | P2 | P3 |
|---|---|:--:|:--:|:--:|:--:|
| **Control Plane** | Admin portal + tenant lifecycle | ✅ (VMS) | ◑ | ✅ | |
| | API automation | ✅ (REST + TF provider) | ✅ | ✅ | |
| | Tenant RBAC | ✅ (VAST managers + Palette RBAC) | ◑ | ✅ | |
| **Tenant Isolation** | VIP pools | ✅ | ◑ | ✅ | |
| | Capacity quotas | ✅ | ✅ | ✅ | |
| | QoS policies | ✅ | | ✅ | |
| **Object Storage (S3)** | Bucket provisioning | ✅ | ✅ | ✅ | |
| | Access key management | ✅ | ✅ | ✅ | |
| | Dataset ingest / migration | ✅ | ◑ | ◑ | |
| **File Storage (NFS)** | View provisioning | ✅ | ✅ | ✅ | |
| | Per-view quota & QoS | ✅ | ◑ | ✅ | |
| **Kubernetes** | CSI driver + PVC | ✅ (driver) | ✅ **(the pack — core P1)** | ✅ | ✅ |
| **Monitoring** | Prometheus integration | ✅ (metrics) | ◑ | ✅ | |
| | Tenant dashboard (cap/IOPS/latency) | | | ✅ (build) | |
| | Grafana integration | | ◑ | ✅ | |
| **Data Protection** | Snapshots (admin-driven) | ✅ | ✅ (CSI snap/clone) | ✅ | |
| | Policy-based replication | ✅ (DataSpace) | | ◑ | ✅ |
| | Multi-region DR orchestration | ◑ | | | ▢ |
| **Managed Data Services** | Managed Database (VAST DB) | ✅ | | | ✅ (P3 bundle) |
| | Managed Vector Database | ◑ (InsightEngine) | | | ◑ |
| | Managed Event Broker (Kafka-compat) | ✅ | | | ◑ |
| **Inference Accel.** | KV-cache performance tier | ◑ | | | ▢ |
| **Block Storage** | Managed NVMe/TCP volumes | ✅ (`vastblock` CSI) | | | ✅ |
| | GPU-attached persistent volumes | ◑ | | | ◑ |
| **Security & Enterprise** | SSO / identity federation | ✅ (SAML/LDAP/AD) | | ◑ | ✅ |
| | BYOK / per-tenant key mgmt | ◑ | | | ▢ |
| | Advanced SLA tiers | ◑ (capacity QoS) | | ◑ | ✅ |

*This is a proposed mapping for review — VoC column reflects native VAST capability; phase columns reflect when the joint integration surfaces it through Palette. Confirm the ◑/▢ items (esp. DataEngine/InsightEngine/KV-cache maturity) with VAST.*

---

## D. Control-plane automation architecture (Palette → VAST)

The goal (Control-Plane doc): a control plane where onboarding a **Palette tenant** automatically provisions **isolated VAST storage with guaranteed QoS**. The mapping:

```
Palette Tenant/Project/Workspace  ──►  VAST tenant (vastdata_tenant, client_ip_ranges)
        │                                   ├─ VIP pool (vastdata_vip_pool, tenant-bound, opt. VLAN)
        │                                   ├─ QoS tier (vastdata_qos_policy: Max/Burst/Credit BW+IOPS)
        │                                   └─ View(s) (vastdata_view: NFS/S3, qos_policy_id, quota)
        ▼
   K8s namespace(s) ──► StorageClass (VIP pool + QoS + view in params)
                    └─► ResourceQuota (storage dim; Spectro RBAC pack ≥1.0.1)
```

**Three ways Palette can trigger the VAST provisioning** (pick per maturity goal):
1. **Terraform (recommended first)** — the official `vast-data/vastdata` provider, run as a Palette **Terraform/IaC step** or out-of-band per-tenant. Lowest effort, GA-grade, declarative. Best for the Phase-2 reference architecture.
2. **Crossplane / operator** — wrap the VMS API (`vastpy`) or the TF provider in a K8s controller so a tenant CR reconciles VAST resources GitOps-style. Best for productizing self-service.
3. **Direct API** — `vastpy`/REST calls from an onboarding workflow. Most flexible, most glue code.

Use a scoped VAST **"manager" API token** (not root) for all automation. **Palette side:** Project = hard isolation boundary; Workspace = cross-cluster namespace grouping enforcing K8s `ResourceQuota` (CPU/mem/storage) + centralized RBAC.

**Publishing the CSI pack ("single-click marketplace" — P1 outcome):** path = the **`spectrocloud/pack-central`** GitHub repo → PR (with README + images listed in `values.yaml` for scanning) → merge → **public OCI Palette Registry** (biweekly Tue/Thu). Caveat: pack-central packs are *unverified*; a *validated/certified* VAST pack is a **Spectro Cloud Partner Program** engagement (contact-driven, not a self-serve cert pipeline). Interim: ship via a **private OCI/ECR registry** (path under `spectro-packs`, push with ORAS) and as an **exportable add-on cluster profile**. For P3, the PaletteAI **ProfileBundle** (Git-managed Helm recipe + `WorkloadProfile`, connected+airgap variants) is the productized vehicle.

---

## E. What we need FROM VAST (consolidated ask list)

These are blockers/inputs only VAST can provide — send as one ask:
1. **VoC entitlement (BYOL) + Polaris portal invite** for account `216938125181` / us-east-2 — longest lead time; start now.
2. **Min VoC footprint + cost** (smallest shown is 3 nodes; confirm minimum + instance type) and **VoC support in us-east-2**.
3. **Full AWS IAM policy** required by `vastcloud` (`vastcloud docs aws-permissions`).
4. **Exact client ports** for S3 and NVMe/TCP (firewall doc didn't pin them).
5. **Whether `vastcloud cluster create` uses the Marketplace CFT or its own CFN/Terraform** (affects our IaC wrapping decision).
6. **DataEngine GA status** + a **DataEngine-enabled** test cluster, and whether its CLI/API is stable enough to script in a bundle.
7. **Test credentials**: VMS endpoint + scoped manager token/user, tenant, VIP-pool DNS, S3 access/secret keys, a provisioned bucket/schema.
8. **Sample data / reference workloads** for P3 validation (and exact repo URLs for the Video-Search / Document-Research sample apps).
9. **Partner Program / pack certification** path for a *validated* (not just community) VAST CSI pack in the Spectro marketplace.

---

## F. Recommended next actions (our side, no VAST dependency)
1. **Build the `vast-csi` pack** (chart 2.6.5) from the `pack-central/csi-driver-nfs-addon` skeleton; publish to a private ECR; test on a throwaway Palette cluster against any NFS backend. (`SCOPING.md` §11)
2. **Write the Terraform** for the network foundation + the `vast-data/vastdata` provider modules (tenant/VIP-pool/QoS/view) — **plan-only** until a VoC endpoint exists. (`SCOPING.md` §10)
3. **Prototype the Palette→VAST mapping** (Project/Workspace → StorageClass + ResourceQuota) as a documented pattern for the Phase-2 reference architecture.
4. **Stand up the load-test harness** (MLPerf Storage / fio Jobs) so it's ready the moment a multi-tenant VoC is available.
