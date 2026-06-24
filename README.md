# VAST on Cloud (VoC) — zero-touch Terraform + CodeBuild

`terraform apply` stands up the network **and** a CodePipeline → CodeBuild that runs VAST's own `vastcloud` CLI to **deploy or destroy** the VoC cluster — driven by a single flag. No manual scripts, no `null_resource`.

```
var.cluster_action = "deploy" | "destroy" | "none"
        │  (baked into the S3 source artifact, so flipping it re-triggers the pipeline)
   terraform apply
        ├─ network: VPC, subnets, NAT, IGW, S3 gateway endpoint, SG (client ports + self-ref)
        └─ archive_file → S3 (versioned) → CodePipeline ─Source(S3)→ CodeBuild
                                                              │
                                          buildspec reads deploy.env → ACTION
                                                              ├─ deploy  → scripts/deploy-voc.sh  → vastcloud cluster create
                                                              └─ destroy → scripts/destroy-voc.sh → vastcloud cluster delete
```

## Layout
```
voc/
├── terraform/
│   ├── network.tf        # VPC/subnets/NAT/IGW/S3-endpoint/SG (+ optional peering)
│   ├── codebuild.tf      # archive_file → S3 → CodePipeline → CodeBuild + IAM
│   ├── variables.tf      # network/peering knobs
│   ├── versions.tf       # aws + archive providers
│   ├── outputs.tf
│   ├── fieldeng.tfvars   # account 211476615597, us-east-2, 10.20.0.0/16
│   └── vast-tenancy/     # post-deploy: tenant/VIP-pool/QoS/view via vast-data/vastdata provider
├── scripts/
│   ├── deploy-voc.sh     # key pair + stale-record cleanup + vastcloud cluster create
│   └── destroy-voc.sh    # vastcloud cluster delete
└── buildspec.yml         # what CodeBuild runs (installs terraform+vastcloud, runs the scripts)
```

## Prerequisites (one-time)
1. **Polaris credentials** in Secrets Manager (JSON), referenced by `var.polaris_secret_id` (default `vast/polaris`):
   ```bash
   aws --profile fieldeng --region us-east-2 secretsmanager create-secret \
     --name vast/polaris \
     --secret-string '{"username":"you@company.com","password":"<polaris-password>"}'
   ```
2. **Remote state backend** (strongly recommended for CI / repeatable runs) — uncomment the `backend "s3"` block in `versions.tf` after creating the bucket + lock table.

## Use
```bash
cd terraform
terraform init

# Deploy: network + pipeline come up, pipeline auto-runs, cluster is created (~30 min in CodeBuild)
terraform apply -var-file=fieldeng.tfvars -var cluster_action=deploy

# Destroy the CLUSTER (keep the infra): flip the flag, pipeline re-runs and deletes it
terraform apply -var-file=fieldeng.tfvars -var cluster_action=destroy
```
Watch the run in the CodePipeline / CodeBuild console (project `vast-voc-fieldeng-lifecycle`), or:
`aws --profile fieldeng codebuild batch-get-builds --ids <id>`.

## ⚠️ Tearing everything down
`terraform destroy` removes the **infra** (network, pipeline, CodeBuild) but **NOT the VoC cluster** — the cluster lives in VAST/Polaris + its own CFN/Terraform, created out-of-band by `vastcloud`, not in this state. **Always delete the cluster first**, then destroy the infra:
```bash
terraform apply  -var-file=fieldeng.tfvars -var cluster_action=destroy   # wait for the pipeline to finish
terraform destroy -var-file=fieldeng.tfvars
```
If you `terraform destroy` while the cluster is up, the i3en.24xlarge keeps billing with no pipeline left to remove it (recover via `scripts/destroy-voc.sh <name>` or the Polaris UI).

## What's baked in (lessons from the first bring-up)
- **SG** opens all VAST client ports **and** self-references for intra-cluster comms (replication/CAS/Silo).
- **S3 gateway endpoint** — VoC nodes in private subnets need S3; the pre-checker fails without it.
- **Key pair** `<cluster>-vastdata-cluster-key` is pre-created (create's pre-checker requires it to exist).
- **Stale-record cleanup** — a failed create leaves a Polaris record; the deploy script deletes it first.
- **Instance size** — `i3en.6xlarge` etc. are **not supported**; VoC enforces **i3en.24xlarge** (~$10.85/hr). Leave `cluster_instance_type` empty.

## Notes / scope-downs
- The **CodeBuild role uses `AdministratorAccess`** (vastcloud creates VPC/EC2/CFN/S3/IAM). Scope down once you know the exact actions.
- CodeBuild runs **outside** the VPC (it only calls AWS + Polaris APIs); the VoC pre-checker tests instance-to-instance connectivity itself.
- **VMS** (`https://<VMS-VIP>`) is reachable from inside the VAST VPC / a peered VPC, not from a laptop or CodeBuild — configure tenants/VIP-pools and CSI from inside the network (`terraform/vast-tenancy`). Rotate the default `admin/123456`.
- **Peering** is off by default (no Palette VPC in fieldeng). Set `enable_peering=true` + `peer_*` vars to connect an existing EKS/k8s VPC.
# vast_polaris_aws_lifecycle
