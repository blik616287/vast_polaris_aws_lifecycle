# EC2 Kubernetes Cluster + VAST Data Platform on AWS — Scoping & Plan

**Account:** `216938125181` · **Region:** `us-east-2` · **AWS profile:** `spectro` (IAM user `specto-dev-tf`, `AdministratorAccess`)
**Date:** 2026-06-23

> **Companion doc:** `VALIDATION-PLAN-RESPONSE.md` — answers to the Validation Plan questions, the reconciled phase roadmap, the populated capability matrix, and the Palette→VAST control-plane automation architecture. This file (`SCOPING.md`) is the AWS/EC2/Palette/VAST **build mechanics**.

## 1. Goal

Stand up a **new EC2-based Kubernetes cluster, provisioned and managed by Spectro Cloud Palette**, that consumes storage from the **VAST Data Platform** deployed on AWS (the "VAST on Cloud" / VoC deployment from the AWS Marketplace listing). Primary consumption path is the **VAST CSI driver** presenting NFS-backed `ReadWriteMany` PersistentVolumes; secondary paths are S3 (COSI) and block (NVMe/TCP) as needed.

## 2. Current-state findings (what already exists)

| Item | Value |
|---|---|
| Palette VPC | `vpc-08271762f662cd3ae` (`vpc-spectroihmeae-ue2`), CIDR `172.20.0.0/16` |
| Public subnets | `172.20.0.0/22` (2a), `172.20.4.0/22` (2b), `172.20.8.0/22` (2c) → IGW `igw-0dbf7fd9e3faf12b8` |
| Private subnets | `172.20.20.0/22` (2a), `172.20.24.0/22` (2b), `172.20.28.0/22` (2c) → NAT `nat-00716ada13fb94edf` (single, in 2a) |
| Existing compute | Palette + Palette AI control nodes (`t3.xlarge`), GPU edge host (`g4dn.2xlarge`), MaaS host (`c5.4xlarge`) |
| EKS | none — Kubernetes here is **Palette-managed**, not EKS |
| Default VPC | `172.31.0.0/16` (unused for this) |
| Key pair | `spectrosvc` |
| EC2 quota | 384 vCPU (Standard On-Demand) — ample |
| Free CIDR space in Palette VPC | `172.20.12.0/22`, `172.20.16.0/22`, `172.20.32.0/19`, … (room to carve VAST/cluster subnets) |

**Implication:** there is established 3-AZ networking and a working Palette stack. We slot the new cluster + VAST into this, not greenfield.

## 3. What "VAST Data Platform on AWS" actually is

- **One product**, delivered via **AWS Marketplace → "VAST Data Platform"** (BYOL). Deployment mode is internally called **"VAST on Cloud" (VoC)**.
- **Deployment is driven by VAST's "Polaris" cloud portal + the `vastcloud` CLI** (not a manual Marketplace CFT). Polaris portal: `https://admin.aws.polaris.vastdata.com/` (invite-only). You build a deployment template in the Polaris UI, then run `vastcloud cluster create --select <NAME>` from a workstation. Under the hood `vastcloud` orchestrates **CloudFormation + Terraform** automation that provisions VAST **into an existing VPC/subnet/SG you specify**. **It is NOT a VAST-managed SaaS VPC + PrivateLink model — you own the VPC and the EC2 instances.** (The Marketplace listing is the entry/entitlement; the actual deploy path is Polaris + `vastcloud`.)
- **Preflight gate:** `vastcloud cluster preflight --provider aws` must return `OK` on all 6 stages (authentication, polaris deployment, permissions, tools[Terraform+AWS CLI], pre-checker[spins a temp EC2 to test metadata/CFN/EC2/S3/internet/intra-cluster ports], conflicts) before `cluster create`.
- **Install `vastcloud`:** `curl https://storage.googleapis.com/polaris-vastcloud/install_vastcloud.sh | bash`; then `vastcloud config init`, `vastcloud login`, `aws sso login --profile <P>`.
- **Polaris template inputs:** entitlement/capacity, deployment name, 12-digit AWS account id, **instance type** (ENodes; e.g. `i7ie.48xlarge` = 192 vCPU/1536 GiB), region, AZ, tags, deployment type (single-node vs full array). Example sizes: 3-node ≈ 360 TiB. No official minimum node count published — smallest shown is 3 nodes (single-node deploy type also exists). **Confirm min footprint + full IAM policy (`vastcloud docs aws-permissions`) with VAST.**
- Architecture = **CNodes** (stateless protocol/compute servers) presenting **data VIPs (VIP Pools)**, plus **VMS** (VAST Management Service) on a **management VIP** (HTTPS UI/REST API). EBS backs capacity in the cloud (vs on-prem NVMe DBoxes).
- **Supported on AWS only with On-Demand instances + Resiliency enabled.**
- **Licensing is BYOL** — entitlement is negotiated/billed directly with VAST, separate from AWS infra cost. **This is a lead-time item** (see §8).
- Protocols presented (all on the data VIPs): **NFS** (v3/v4), **SMB**, **S3**, **block via NVMe/TCP**, plus **VAST DataBase** (Trino/Spark/Dremio connectors + Python SDK).

## 4. How the k8s cluster consumes VAST

Install the **VAST CSI driver** (`github.com/vast-data/vast-csi`, charts: `vastcsi` NFS, `vastblock` NVMe/TCP, `vastcosi` S3/COSI, or `vastcsi-operator`).

- **Controller pod (singleton):** talks to the **VMS REST API** to create/delete volumes (each PV = a VAST view = directory + quota).
- **Node DaemonSet (per host):** performs the actual NFS/NVMe mount.
- **Load-bearing config** (`values.yaml` / secret):
  - `endpoint` → VMS REST API VIP (controller must reach it)
  - credentials secret: `username`+`password` **or** `token`, optional `tenant`, `ssl_cert`/`verifySsl`
  - `vipPool` (name) **or** `vipPoolFQDN` (DNS; faster, `vipPoolFQDNRandomPrefix: true` to load-balance) → the data VIPs nodes mount from
  - StorageClass: `storagePath`, `viewPolicy`, `qosPolicy`, `reclaimPolicy`, `allowVolumeExpansion`
- Default output: **NFS RWX PVs**. Block (NVMe/TCP) and object (COSI) optional.

### The two reachability requirements (this is the crux of the plan)
1. **CSI controller → VMS REST API** on **443**
2. **Every k8s node → VAST data VIP pool**: NFS **2049/tcp** (v4); + **111** & **20048** (v3 portmapper/mountd); **443** for S3; NVMe/TCP for block

Plus VAST multi-tenancy filters by **Client IP Range** per tenant — k8s node source IPs must fall inside an allowed range (NAT at VPC boundary is the documented pattern to map traffic to allowed routable IPs).

## 5. Key architecture decision — network topology

This is the one decision that drives everything else. Three viable options:

### Option A — VAST + new k8s cluster both in the existing Palette VPC (`172.20.0.0/16`)
- VoC CFT targets `vpc-08271762f662cd3ae`; carve new `/22`s (e.g. `172.20.12.0/22` for VAST data, `172.20.16.0/22` for k8s nodes) from free space.
- **Pro:** simplest routing (all local, no peering), lowest latency, no cross-VPC SG complexity.
- **Con:** VAST + new cluster share blast radius with the Palette management plane; weakest isolation.

### Option B — VAST in its own dedicated VPC, peered to the k8s VPC ⭐ recommended
- New VPC for VoC (e.g. `10.20.0.0/16`); VPC peering (or TGW) to wherever the Palette cluster's nodes live.
- **Pro:** clean separation of storage infra from compute/management; easier to right-size SGs; matches VAST's tenant-NAT/Client-IP-Range model; storage can outlive/scale independently of any one cluster.
- **Con:** peering + route-table + cross-VPC SG management; mind non-overlapping CIDRs.

### Option C — VAST in existing VPC, new k8s cluster in its own VPC (Palette-created), peered
- Hybrid; reasonable if Palette is configured to create a fresh VPC per cluster.

**Recommendation: Option B.** Storage is long-lived infrastructure that multiple clusters/tenants will likely share over time; isolating it in its own VPC gives the cleanest security boundary and aligns with VAST's IP-range/NAT tenancy model. Decide this first because it determines whether the new Palette cluster reuses the Palette VPC or gets its own. **(Confirm: does Palette here provision into an existing VPC or create a new one per cluster?)**

## 6. Capacity & instance sizing (baseline — tune to workload)

- **VAST CNodes (VoC):** instance type chosen at CFT deploy time; storage/throughput-optimized NVMe families (**i3en / i4i**, up to 100 Gbps) are the relevant class; EBS backs capacity. **Confirm minimum supported cluster footprint (CNode count + capacity floor) with VAST** — there is a minimum and it sets your baseline cost.
- **k8s client nodes:** no special instance/EBS requirement to mount VAST — standard families work. NFS/S3 are network-bound, so for AI/throughput workloads use 25–100 Gbps-capable nodes and **place them in the same AZ as the VIP pool** to minimize latency and cross-AZ data charges.
- **AZ strategy:** the existing layout spans 2a/2b/2c but has only **one NAT (in 2a)** — for an HA cluster add NAT per AZ, or accept the single-AZ-egress dependency.

## 7. Phased execution plan

**Phase 0 — Decisions & procurement (blocking, has lead time)**
- [ ] Engage VAST sales: BYOL entitlement/license + confirm min cluster size & supported region (us-east-2)
- [ ] Subscribe to **VAST Data Platform** in AWS Marketplace (yields the CFT)
- [ ] Choose network topology (§5; recommend Option B)
- [ ] Confirm whether Palette provisions into existing VPC or creates its own

**Phase 1 — Network foundation**
- [ ] If Option B: create VAST VPC (non-overlapping CIDR), subnets across AZs, IGW/NAT as needed
- [ ] VPC peering (or TGW) + route tables between VAST VPC and k8s node VPC
- [ ] Security groups: k8s nodes → VAST VIPs (2049/111/20048/443 + NVMe/TCP); CSI controller → VMS 443; SSH for admin
- [ ] Plan/implement tenant **Client IP Range** + NAT so node source IPs are allowed by VAST

**Phase 2 — Deploy VAST (VoC via Polaris)**
- [ ] Get Polaris portal access (invite) + BYOL entitlement; build the deployment template (account id, instance type, region, AZ, capacity, tags)
- [ ] Install `vastcloud` CLI; `vastcloud config init` / `login`; `aws sso login` (or static keys for `spectro`)
- [ ] `vastcloud cluster check-permissions --provider aws`
- [ ] **Preflight gate:** `vastcloud cluster preflight --provider aws --region us-east-2 --subnet <id> --aws-security-groups <id>` → all 6 stages `OK`
- [ ] `vastcloud cluster create --select <NAME>` into the target VPC/subnet/SG; On-Demand + Resiliency
- [ ] Post-deploy: log into VMS (`https://<VMS_VIP>/`), create **tenant**, **VIP pool(s)**, **view policy**, and a **service account/token** for CSI

**Phase 3 — Provision the Palette k8s cluster**
- [ ] Build the Palette cluster profile (k8s version, CNI, add-ons) for an EC2 cluster
- [ ] Provision worker node pool(s) into subnets with routing to the VAST VIP pool (same AZ as VIPs where possible)
- [ ] Verify node → VIP reachability (`showmount`/`nc` to 2049) and controller → VMS 443

**Phase 4 — Build vast-csi pack & install/validate CSI** (see §11)
- [ ] Build the `vast-csi` Palette pack (chart `vastcsi 2.6.5`) and publish to ECR via `oras`; register registry in Palette
- [ ] Whitelist privileged pods for the `vast-csi` namespace; install snapshot CRDs (if snapshots wanted)
- [ ] Create the `vastsecret` credentials secret; ensure VAST View Policy allows worker-node subnet CIDRs
- [ ] Attach the pack as an add-on layer; set `endpoint` (VMS VIP) + `vipPool`/`storagePath`/`viewPolicy`
- [ ] Create StorageClass(es); test `ReadWriteMany` PVC + multi-pod write, volume expansion, snapshot
- [ ] (Optional) `vastblock` (NVMe/TCP) and `vastcosi` (S3) layers if those access modes are needed

**Phase 5 — Hardening & ops**
- [ ] Per-AZ NAT / HA review; backup/snapshot policy; monitoring of VMS + VIP pool; QoS policies; document runbook

## 8. Prerequisites / open questions to resolve

1. **VAST BYOL license** — must be sourced from VAST; longest lead time. Start now.
2. **Min VAST footprint & cost** — confirm with VAST (drives baseline spend).
3. **Topology choice** (§5) and **Palette VPC behavior** (existing vs new).
4. **Workload profile** for the k8s cluster — node count/size, GPU?, throughput target (drives node + VIP pool sizing).
5. **Region** — confirm VoC is supported/available in `us-east-2`.
6. **HA expectations** — single-AZ vs multi-AZ for both VAST and the cluster (affects NAT, VIP pool spread, cost).
7. **Access modes needed** — NFS only, or also S3 (COSI) / block (NVMe/TCP) / VAST DataBase.

## 9. Risks

- **No public Terraform module** — VAST deploy is CloudFormation-only; IaC means wrapping/importing the CFT. Plan VAST as CFT-managed, the rest as your IaC.
- **BYOL lead time** could block everything else — front-load Phase 0.
- **Single NAT** in current VPC is an HA gap for any cluster relying on it.
- **Tenant IP-range/NAT** misconfiguration is the most likely cause of "mounts hang" — validate reachability *and* that source IPs are in the allowed range before installing CSI.
- **Cross-AZ data transfer** cost if k8s nodes and VIP pool land in different AZs.

## 10. Terraform plan (infrastructure-as-code scope)

**Principle:** Terraform owns the *connective AWS infrastructure*; it does **not** deploy VAST (that's Polaris/CFT — see §3) and does **not** create the k8s cluster (that's Palette/CAPI). TF provisions everything in between so both have a stable, version-controlled substrate. Apply via the `spectro` profile (`AdministratorAccess`). **Plan-only first — `terraform plan` reviewed before any apply.**

### In scope for Terraform
| Module | Resources | Notes |
|---|---|---|
| `network-vast` (Option B) | VPC, subnets (3-AZ), IGW, NAT(s), route tables | Non-overlapping CIDR (e.g. `10.20.0.0/16`); skip if Option A |
| `peering` | VPC peering connection (or TGW attachment) + routes on both sides | VAST VPC ↔ Palette/k8s VPC; add return routes in `172.20.0.0/16` tables |
| `security-groups` | SG: k8s nodes → VAST VIPs (2049/111/20048/443/NVMe-TCP); SG: CSI controller → VMS 443; admin/SSH | Exact ports from VoC firewall doc (pending KB digest) |
| `iam` | Keypair (reuse `spectrosvc` or new), any IAM roles/policies Polaris/CFT requires as inputs | CFT may need a service role / instance profile |
| `inputs-for-polaris` | Outputs: VPC id, subnet ids, SG ids, keypair name | Feed these into the Polaris/CFT deployment as parameters |
| (optional) `network-extras` | Per-AZ NAT for HA, VPC endpoints (S3/STS), flow logs | Closes the single-NAT HA gap noted in §6 |

### Out of scope for Terraform (managed elsewhere)
- VAST VoC cluster → **Polaris / Marketplace CFT** (could be `terraform import`ed or wrapped with `aws_cloudformation_stack` if you want one pane of glass — decision point)
- Kubernetes cluster + node pools → **Palette** cluster profile
- vast-csi → **Palette pack** (Helm), not raw TF

### Backend & workflow
- [ ] State backend: S3 bucket + DynamoDB lock table in `216938125181` (create once, can be a tiny bootstrap TF or console)
- [ ] Provider pinned to `profile = "spectro"`, `region = "us-east-2"`
- [ ] Structure as reusable modules; one root per environment
- [ ] **Workflow: `terraform plan` → review → user approves → `terraform apply`** (no auto-apply)
- [ ] Decision: wrap the VAST CFT in `aws_cloudformation_stack` (single IaC pane) vs keep Polaris-driven and only import outputs

This maps directly onto **Phase 1** (network foundation) above — Phase 1 becomes "write + plan the Terraform, review, apply."

## 11. Build the vast-csi Palette pack (concrete deliverable)

Spectro Cloud Palette consumes add-ons as **packs** (versioned dir of metadata + content) attached as a **layer** in a cluster profile. We build a **Helm-based add-on pack** wrapping the official VAST CSI chart.

### Source artifacts (pin these)
- Helm repo `https://vast-data.github.io/vast-csi`, chart **`vastcsi/vastcsi@2.6.5`**
- Images: `vastdataorg/csi:v2.6.5` + sig-storage sidecars (`csi-provisioner:v4.0.0`, `csi-attacher:v4.5.0`, `csi-snapshotter:v7.0.1`, `csi-resizer:v1.10.0`, `csi-node-driver-registrar:v2.10.0`)
- CSI driver / provisioner id: **`csi.vastdata.com`**

### Pack directory layout
```
vast-csi/
├── pack.json        # metadata: name, displayName, version, layer:addon, addonType:storage, cloudTypes
├── values.yaml      # VAST-specific knobs exposed in the profile UI
├── logo.png
└── charts/
    └── vast-csi.tgz # `helm package` of vastcsi 2.6.5
```
`pack.json` skeleton:
```json
{ "name": "vast-csi", "displayName": "VAST CSI Driver", "version": "2.6.5",
  "layer": "addon", "addonType": "storage", "cloudTypes": ["aws","eks"],
  "kubeManifests": [], "charts": ["charts/vast-csi.tgz"] }
```
`values.yaml` exposes (merged over chart defaults): `endpoint` (VMS VIP), `secretName` (`vastsecret`), `verifySsl`, and `storageClasses.<name>.{vipPool,storagePath,viewPolicy,mountOptions}`. Operators override per cluster profile in the layer's YAML editor — no pack rebuild needed.

### Build → publish → attach
1. Clone `github.com/spectrocloud/pack-central/packs/csi-driver-nfs-addon` as the skeleton.
2. `helm package` vastcsi 2.6.5 → drop `.tgz` in `charts/`; rewrite `pack.json` + trim `values.yaml`.
3. Publish — **Option B (OCI/ECR) recommended** since targets are AWS:
   ```bash
   tar -czf vast-csi-2.6.5.tar.gz vast-csi
   oras push $ECR/$PROJECT/spectro-packs/archive/vast-csi:2.6.5 vast-csi-2.6.5.tar.gz
   ```
   (Path **must** contain `spectro-packs/archive`; ORAS v1.0.0.) Or Option A: `spectro pack push ./vast-csi`.
4. Register the registry in Palette (Tenant Settings → Registries).
5. Add it as an **add-on layer** in the cluster profile → set VAST endpoint/creds/storageClass → attach to the cluster; Palette reconciles and Helm-installs.

### Pack/cluster prerequisites & gotchas
- **Secret** (not in pack): `kubectl -n vast-csi create secret generic vastsecret --from-literal=username=admin --from-literal=password=...`
- **Snapshot CRDs** (external-snapshotter v6.0.1) once per cluster if snapshots are wanted.
- ⚠️ **The CSI node DaemonSet needs privileged pods** — Palette/Kyverno/OPA/Pod Security Admission can block it. Whitelist the `vast-csi` namespace. This is the most likely deployment blocker.
- The VAST **View Policy must allow the worker-node subnet CIDRs**, and routing must exist node→VIP.
- CSI portion is **fully generic Kubernetes** — none of the EKS `eksctl`/IAM/SSO steps from VAST's EKS doc carry to a Palette-managed cluster; only the namespace/secret/CRD/Helm/StorageClass steps do.

## 12. Firewall / ports (from VoC firewall prerequisites)

**From k8s workers → VAST (the rules you must add to SGs):**
| Purpose | Port(s) | Proto |
|---|---|---|
| NFS data path | 2049, 111, 20048 (+20106/20107 NLM/NSM, 20108 rquota) | TCP |
| VMS mgmt / REST API (CSI controller) | 443 (and 80) | TCP |
| S3 | 80 / 443 (no dedicated port listed — confirm) | TCP |
| SMB (if used) | 445 (+AD 389/636/3268/3269) | TCP |
| NVMe/TCP block (if used) | 4420/4520 listed as "SPDK Target" — **confirm with VAST** | TCP |
| SSH admin | 22 | TCP |

The large internal/UDP port list (4000–7100 ranges, silos, leader, replication 49001/49002, etc.) is **VAST-internode only** — handled by the VoC SG the Polaris deploy creates, *not* something your k8s workers need outbound. **Gaps to confirm with VAST:** exact S3 and NVMe/TCP client ports.

## 13. RDMA / high-throughput networking (EFA)

**The headline finding — set expectations here:** RDMA on AWS = **EFA (Elastic Fabric Adapter)**, which is **not** RoCE/InfiniBand. The EFA kernel driver supports only **UD and SRD queue pairs; RC queue pairs and kernel ULPs are NOT supported**. NFSoRDMA (`xprtrdma`) is a kernel ULP that requires RC verbs → **NFSoRDMA cannot run over EFA**. On-prem VAST uses NFSoRDMA/RoCE; **VAST on Cloud on AWS serves its data path over plain TCP/IP (NFS over TCP, NVMe/TCP) — there is no RDMA path from k8s clients to VAST storage on AWS.** (Confirmed by the EFA driver limitation; the gated VAST "VoC for AWS" admin page would make it explicit — worth a login-check, but safe to plan around.)

So RDMA splits into two separate questions:

| Use case | RDMA on AWS? | How |
|---|---|---|
| **k8s node → VAST storage (NFS/S3/block)** | ❌ No | TCP only. Optimize throughput another way (below). |
| **node ↔ node GPU collectives (NCCL, distributed training)** | ✅ Yes | EFA + `aws-ofi-nccl`, on EFA-capable instances in a cluster placement group |

### What actually buys throughput **to VAST** (TCP path)
- **High-bandwidth instances**: 100 Gbps-class — `i4i`, `i3en.24xlarge`, `c6in`/`c7gn`, `m5n/r5n`, GPU `p4d/p5`. Network bandwidth is the lever, not RDMA.
- **NFS `nconnect`** (multiple TCP connections per mount) + **VIP-pool load-balancing** (`vip_pool_fqdn_random_prefix: true`, `lb_strategy: roundrobin`) to spread across CNodes.
- **Co-locate** k8s nodes in the **same AZ** as the VIP pool (latency + avoids cross-AZ data charges).
- Consider **multiple mounts / multiple StorageClasses** across VIP pools for parallelism.

### If you want EFA for GPU node-to-node (AI training)
- **EFA-capable instances** (subset): `p4d.24xlarge`, `p5.48xlarge`, `c5n.18xlarge`, `i3en.24xlarge`, `c6in.32xlarge`, `hpc6a/hpc7`, some `g`-series. Must be in a **cluster placement group**, **single subnet/AZ**, and the **SG must self-reference allowing all traffic within the SG**.
- **k8s enablement (non-EKS/Palette)**: `aws-efa-k8s-device-plugin` DaemonSet (runs privileged + hostNetwork, mounts `/dev/infiniband`); EFA driver baked into the node AMI; **hugepages** (EFA AMIs pre-allocate ~5128×2Mi; workloads request e.g. `hugepages-2Mi`). Workload pods just request the `vpc.amazonaws.com/efa` resource.
- ⚠️ **Palette gotchas:** (1) the device-plugin chart targets nodes via `node.kubernetes.io/instance-type`, populated by the **AWS cloud-controller-manager** — confirm the Palette cluster runs AWS CCM or set an explicit `nodeSelector`; (2) the newer **EFA DRA driver is EKS-only** — the **device plugin is the portable choice** for a Palette cluster; (3) this is a **second potential Palette pack** (EFA device plugin) alongside vast-csi.

**Net:** plan VAST access as **high-bandwidth TCP** (no RDMA), and treat EFA/RDMA purely as an *optional GPU node-to-node* capability for distributed training, delivered as its own add-on — not as a storage accelerator.

## Net summary

1. **Deploy VAST (VoC)** via the **Polaris portal + `vastcloud` CLI** (preflight must hit 6× `OK`) into its own VPC (recommended), peered to the Palette cluster's VPC.
2. **Provision the cluster** with **Palette** (EC2, not EKS), node pools in a subnet routed to the VAST VIP pool, same AZ where possible.
3. **Guarantee two reachability paths** — **CSI controller → VMS:443** and **every node → VIP pool (NFS 2049/111/20048 + friends)** — with node source IPs inside an allowed VAST **View Policy / Client IP Range**.
4. **Terraform** owns the connective network/SG/IAM substrate (plan → review → apply); **Polaris** owns VAST; **Palette** owns the cluster + the **vast-csi pack** (chart 2.6.5) that yields NFS RWX PVs.
5. **RDMA:** there is **no RDMA path to VAST storage on AWS** (EFA can't do NFSoRDMA) — get throughput via 100 Gbps TCP instances + NFS `nconnect` + VIP-pool LB. EFA/RDMA is an optional **GPU node-to-node** add-on only.
6. **Long-poles / blockers:** ① **VAST BYOL license + Polaris invite** (start now); ② **privileged-pod policy** must allow the CSI node DaemonSet; ③ confirm Palette runs **AWS CCM** if using EFA. Open items to confirm with VAST: min cluster footprint, exact S3/NVMe-TCP client ports, full IAM policy.
