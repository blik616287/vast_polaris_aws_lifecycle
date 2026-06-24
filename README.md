# vast_polaris_aws_lifecycle

Zero-touch lifecycle for a **VAST on Cloud (VoC)** cluster on AWS, driven entirely by Terraform + a flag.

`terraform apply` stands up the supporting AWS infrastructure **and** an AWS **CodePipeline → CodeBuild** that runs VAST's own `vastcloud` CLI to **deploy or destroy** the VoC cluster. You never run the cluster tooling by hand — you flip one variable and apply.

```
var.cluster_action = "deploy" | "destroy" | "none"
        │   (baked into an S3 source artifact — flipping it re-triggers the pipeline)
   terraform apply
        ├─ infra:  VPC · subnets · NAT · IGW · S3 gateway endpoint · SG
        │          S3 artifact bucket · CodePipeline · CodeBuild · IAM   ← Terraform owns this
        └─ archive_file → S3 (versioned) → CodePipeline ─Source(S3)→ CodeBuild
                                                              │ reads deploy.env → ACTION
                                                              ├─ deploy  → vastcloud cluster create
                                                              └─ destroy → vastcloud cluster delete   ← vast CLI owns the cluster
```

---

## Quickstart

### Prerequisites
- Terraform ≥ 1.5, AWS CLI v2, an AWS profile with admin on the target account (default profile name: `fieldeng`).
- A **VAST Polaris** account/entitlement and login credentials (the `vastcloud` CLI authenticates to Polaris).

### 1. Put the Polaris credentials in Terraform (gitignored)
Terraform creates the `vast/polaris` Secrets Manager secret from these; CodeBuild reads it for non-interactive Polaris login.
```bash
cd terraform
cp secrets.auto.tfvars.example secrets.auto.tfvars   # gitignored
# edit secrets.auto.tfvars:
#   polaris_username = "you@company.com"
#   polaris_password = "********"
```

### 2. Stand up the infra + pipeline (no cluster yet)
```bash
terraform init
terraform apply -var-file=fieldeng.tfvars -var cluster_action=none
```

### 3. Deploy a cluster
```bash
terraform apply -var-file=fieldeng.tfvars -var cluster_action=deploy
```
The pipeline runs CodeBuild → `vastcloud cluster create` (~30 min; provisions a real `i3en.24xlarge`, **~$10.85/hr**). Watch it in the CodePipeline/CodeBuild console (`vast-voc-fieldeng-lifecycle`).

### 4. Destroy the cluster (keep the infra)
```bash
terraform apply -var-file=fieldeng.tfvars -var cluster_action=destroy
```
Pipeline runs CodeBuild → `vastcloud cluster delete` → the node is terminated.

### 5. Tear everything down
```bash
terraform destroy -var-file=fieldeng.tfvars
```
Safe: a destroy-time guard fires the teardown CodeBuild (`vastcloud cluster delete`) **before** removing the infra, so the cluster never orphans. (You can also do step 4 first, then destroy.)

> **Cost:** the only idle cost is one NAT gateway (~$32/mo). A running cluster is **~$10.85/hr** (`i3en.24xlarge` — VoC's enforced minimum). Deploy → test → destroy.

---

## Layout
```
voc/
├── terraform/
│   ├── network.tf        # VPC/subnets/NAT/IGW/S3-gateway-endpoint/SG (+ optional peering)
│   ├── codebuild.tf      # archive_file → S3 → CodePipeline → CodeBuild + teardown guard + IAM
│   ├── secrets.tf        # vast/polaris Secrets Manager secret from sensitive vars
│   ├── variables.tf, versions.tf, outputs.tf
│   ├── fieldeng.tfvars   # env config (account 211476615597, us-east-2, 10.20.0.0/16)
│   ├── secrets.auto.tfvars.example   # template → copy to secrets.auto.tfvars (gitignored)
│   └── vast-tenancy/     # post-deploy: tenant/VIP-pool/QoS/view via the vast-data/vastdata provider
├── scripts/
│   ├── deploy-voc.sh     # idempotent create (discovery cross-ref → vastcloud cluster create)
│   └── destroy-voc.sh    # discovery → vastcloud cluster delete (idempotent)
└── buildspec.yml         # CodeBuild: install/auth tooling, then run the scripts
```

---

## Technical analysis

### The architecture boundary (why two layers)
There are two distinct ownership domains, and they never cross:

| Layer | Owned by | Lifecycle | State |
|---|---|---|---|
| **Infra** — network, S3, CodePipeline, CodeBuild, IAM | **Terraform** (run on your machine / CI) | `terraform apply` / `terraform destroy` | your Terraform state |
| **VoC cluster** — EC2/ASG/ENIs/etc. | **`vastcloud` CLI** (inside the CodeBuild subshell) | `cluster create` / `cluster delete` | VAST-managed (Polaris + per-cluster S3 state bucket) |

Terraform must never delete the cluster directly, and the vast CLI never touches Terraform's infra. The flag-driven pipeline is the bridge: Terraform renders the desired `ACTION` into the S3 source artifact, and CodeBuild executes the corresponding vast-CLI command.

### What Polaris is
**Polaris is VAST's hosted SaaS control-plane** for VoC (`api.aws.polaris.vastdata.com`). The `vastcloud` CLI logs into it; it holds your **entitlement/subscription** and is meant to track your clusters. The cluster itself runs in **your** AWS account — Polaris orchestrates, your account is the data plane. This is an **external dependency**: CodeBuild needs outbound internet to Polaris plus the login secret for any create/delete.

### Why a flag re-triggers the pipeline (no `null_resource`)
`var.cluster_action` is written into `deploy.env`, which is zipped (`archive_file`) into the S3 source object. Changing the flag changes the artifact hash → the S3-sourced CodePipeline detects a new version → it re-runs. Pure declarative Terraform; no `null_resource`/`local-exec` to drive the deploy.

The one place Terraform *does* trigger CodeBuild imperatively is a **`terraform_data` destroy-time guard**: on `terraform destroy` it runs the teardown CodeBuild and waits, so the cluster is removed (by the vast CLI) before the infra disappears.

### Credentials: ambient role, materialized for subprocesses
CodeBuild authorizes via its **IAM service role** (no static keys). But `vastcloud` shells out to its own bundled `terraform` with a **sanitized environment** — no IMDS (CodeBuild isn't EC2) and no container-credential endpoint — so those subprocesses can't see the role. The buildspec therefore **materializes the role's own short-lived session credentials** (fetched at runtime from the container endpoint) into `~/.aws/credentials` for both `default` and the named profile. They're temporary, fetched per build, and never committed. (`credential_process` was tried first but vastcloud's subprocesses don't inherit the endpoint it needs.)

### State discovery: deploy/destroy across ephemeral containers
`vastcloud` tracks clusters in three places: **Polaris**, **local `~/.vast` state**, and the per-cluster **`vast-cluster-<name>` S3 bucket** (its terraform state). A CodeBuild deploy leaves the cluster tracked in *neither* Polaris nor any persistent local state — so a fresh container's `cluster list` is empty and `cluster delete` reports "not found", which would **orphan a billing node**.

The fix is `vastcloud cluster list --include-bucket-discovery` — it scans the `vast-cluster-*` S3 buckets for "clusters not tracked by Polaris." Every cluster operation uses it:
- **Deploy** cross-references the discovered list against the requested name → **idempotent** (if it already exists, the build is a clean no-op; it never rebuilds).
- **Destroy** discovers the cluster from S3, then `cluster delete` → terminates the node (idempotent: no-op if already gone).

### Gotchas baked in (lessons from bring-up)
- **Security group** opens all VoC client ports **and** self-references for intra-cluster comms (replication / CAS / Silo).
- **S3 gateway endpoint** is required — VoC nodes sit in private subnets and the pre-checker's S3 probe fails without it.
- **Key pair** `<cluster>-vastdata-cluster-key` is pre-created (create's pre-checker requires it to exist; `create` has no `--aws-key-name`).
- **Instance size:** smaller `i3en` sizes are silently unsupported — VoC enforces **`i3en.24xlarge`**. Leave `cluster_instance_type` empty.
- **CodePipeline S3 source** needs `s3:*` on the artifact bucket (it uses `ListBucketVersions`/`GetObjectTagging`/`GetBucketLocation`, not just basic reads).
- **Buildspec runs in `sh` (dash)** — use `set -eu`, not `set -o pipefail`.
- Terraform heredocs escape shell `${...}` as `$${...}`.

### Scope-downs / notes
- The **CodeBuild role uses `AdministratorAccess`** (vastcloud creates VPC/EC2/CFN/S3/IAM). Scope down once the exact action set is known.
- CodeBuild runs **outside** the VPC — it only calls AWS + Polaris APIs; the VoC pre-checker tests node-to-node connectivity itself.
- The cluster **VMS** (`https://<VMS-VIP>`) is reachable only from inside the VAST VPC or a peered VPC — configure tenants/VIP-pools/CSI from there (`terraform/vast-tenancy/`). Rotate the default `admin/123456`.
- **Peering** is off by default. Set `enable_peering=true` + `peer_*` vars to connect an existing EKS/k8s VPC.
- For CI / shared state, enable the **remote S3 backend** (commented in `versions.tf`) — the state contains the Polaris secret, so keep it encrypted and private.
