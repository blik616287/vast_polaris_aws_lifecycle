# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Spectro Cloud Palette pack-development workspace** for the VAST Data add-on packs (CSI/NFS, COSI/S3, Block/NVMe-TCP). The end goal (`instructions.txt`): build a Palette **cluster profile with an AWS infrastructure layer**, deploy a k8s cluster on it, then **upload → sync → validate** the packs in `testpacks/` so that Palette-managed cluster (in AWS profile `spectro`) consumes storage from the **VAST appliance deployed in AWS profile `fieldeng`** (the VoC cluster from the parent `voc/` lifecycle).

Two AWS accounts are in play: **`spectro`** hosts the Palette control plane + the ECR-backed pack registry; **`fieldeng`** hosts the VAST cluster. `../` (the `voc/` repo) is what stands up the VAST side.

## Environment (in `instructions.txt`)

- **Palette API:** `https://palette.isc-spectro-dev.click` (tenant-scoped: `https://default.palette.isc-spectro-dev.click`). Auth header: `ApiKey: <token>`. The non-TTL default-tenant token is in `instructions.txt` — read it from there, never hard-code or echo it.
- **ECR pack registry** (account `216938125181`, `us-east-2`, reachable via the `spectro` profile): `216938125181.dkr.ecr.us-east-2.amazonaws.com`. Palette scans packs at the path `spectro-packs/spectro-packs/archive/<name>:<version>`. Palette registry UID for sync: `6a29d1b56365d069e5ac1d81`.

## Layout

- **`testpacks/`** — the packs under active development (`vast-csi`, `vast-cosi`, `vast-block`, all `2.6.5`). Each is a Helm-based pack: `pack.json` + `values.yaml` + `charts/<chart>-<ver>.tgz` + `logo.png` + `README.md`.
- **`upload.sh`** — the round-trip publisher (push + verify + Palette sync + catalog poll + validate). The real tool for getting packs into Palette here.
- **`pack-central/`** — a clone of Spectro's community pack repo, used as the **reference for conventions + validation**: `validator/` (PR validation), `scripts/push_packs.sh` (Spectro-CLI push), `templates/` (README template/example), `.github/workflows/` (pack-validation + push), and `packs/` (~dozens of example packs to copy patterns from). This is reference material, not the thing being shipped.

## Commands

```bash
# Validate packs LOCALLY before publishing — render + install + build-on-deploy
# on a throwaway kind cluster (catches the bugs cloud deploys take ~20 min to find).
cd packtest && go run .            # render+install gates, all 3 packs (~30s)
cd packtest && go run . -pods      # also exercise build-on-deploy (fetch-runtime init)
cd packtest && go run . -keep -packs vast-cosi   # one pack, keep cluster for inspection

# Publish testpacks to the ISC Palette ECR registry + verify the full round-trip
PALETTE_APIKEY=<token> ./upload.sh testpacks/vast-csi-2.6.5 testpacks/vast-cosi-2.6.5 testpacks/vast-block-2.6.5
PALETTE_APIKEY=<token> SKIP_SYNC=1 ./upload.sh testpacks/vast-csi-2.6.5   # push+verify only, no Palette sync
# Env overrides: AWS_PROFILE(spectro) AWS_REGION(us-east-2) REGISTRY_NAME(spectro-packs)
#                PALETTE_API PALETTE_REG_UID SYNC_TIMEOUT(360)

# Validate a pack the way pack-central's PR CI does (jq + JSON-schema + version + values indentation)
pack-central/validator/validate-packs.sh         # schema: pack-central/validator/pack-schema.json
pack-central/validator/validate-values.sh <values.yaml>

# Raw push (what upload.sh wraps), per instructions.txt
oras push 216938125181.dkr.ecr.us-east-2.amazonaws.com/spectro-packs/spectro-packs/archive/<name>:<version> <pack>.tar.gz
```

## Architecture / conventions that span files

**`upload.sh` is the load-bearing piece.** Its flow per pack: build `<name>-<version>.tar.gz` → `oras push` to `<registry>/spectro-packs/archive/<name>` tagged `:<version>` (creating the ECR repo if absent) → `oras manifest fetch` to confirm it landed → `POST /v1/registries/pack/<reg-uid>/sync` to trigger Palette → poll `GET /v1/packs/<name>/registries/<reg-uid>` until the version tag appears → assert `packValues` is non-empty. Non-obvious requirements baked in:
- **Pack dir name MUST be exactly `<name>-<version>`** (matched against `pack.json`'s `name`/`version`); the tarball and OCI layer title must be the bare `<name>-<version>.tar.gz` (Palette's scanner keys off it) — don't push a dir-prefixed path.
- Packs sharing a `name` publish as separate **version tags of one repo** (repo = name, tag = version), so keep `name`/`displayName` stable across versions.

**Pack structure (Helm-based add-on).** `pack.json` is metadata only (`name`, `displayName`, `version`, `layer` are required by `pack-central/validator/pack-schema.json`; plus `addonType`, `cloudTypes`, `charts: ["charts/<chart>.tgz"]`). The actual workload is the bundled chart tgz; `values.yaml` is the pack-level override layer Palette renders in the cluster-profile editor. Validation rules to respect (from `validator/validate-packs.sh`): valid JSON, schema-conformant `pack.json`, **version must not start with `v`**, and `values.yaml` indentation must be consistent. List every container image under the `images:`/`pack.content.images` section of `values.yaml` so it can be security-scanned (a hard requirement for pack-central PRs; see its `README.md`).

**The VAST packs' runtime config** (in each `testpacks/*/values.yaml`) points the CSI/COSI/block driver at the VAST cluster's **VMS endpoint + VIP pool**, with a `vast-mgmt` credentials secret — i.e. the `fieldeng` VoC cluster's VMS, reachable from the Palette (`spectro`) cluster over VPC peering. The CSI node DaemonSet needs **privileged** pods (whitelist the namespace). See each pack's `README.md` and the parent `../README.md` / `../../SCOPING.md` for the cross-account networking.

**Local validation (`packtest/`)** is a Go tool that stands up a kind cluster and renders/installs each pack the way Palette would — the fast inner loop for pack development. Two non-obvious **CRD prerequisites** it surfaced (the charts fail to install without them, both in kind and in a real Palette cluster profile): `vast-csi` auto-creates a `VolumeSnapshotClass` (needs `snapshot.storage.k8s.io` CRDs — the `external-snapshotter` pack or a snapshot-CRD layer), and `vast-cosi` creates a `BucketClass` (needs `objectstorage.k8s.io` COSI CRDs). **Build-on-deploy** is validated by the `fetch-runtime` init container exiting 0 (it crane-exports the driver + sidecars onto `wolfi-base`); the driver itself can't run without a reachable VMS, so its crash under test is expected. **`vast-block` node prereqs:** the block driver needs the `nvme-tcp` kernel module + the `nvme-cli` tool on the node (both absent from the base Ubuntu AWS image; the cluster profile provides them via a `preKubeadmCommands` step in `infra/kubernetes.yaml`). Since kind shares the host kernel, `packtest -pods` mirrors that by `sudo modprobe nvme-tcp` on the host + `docker exec`-installing `nvme-cli` into the kind node before the block pods start — so the block driver actually loads and serves locally. `-skip-block-prereq` leaves them out to reproduce the `block-node-prereq` driver-load failure (CrashLoopBackOff on `try_nvme_probes`/`nvme version`). The pods gate requires **two consecutive clean polls** and scans any restarted container, so a startup-probe crash can't slip through during a transient-Running window.

**Reference, not target:** `pack-central/` is Spectro's repo with its own CI (`.github/workflows/pack-validation.yml`, `push-packs.yml`) and `scripts/push_packs.sh` (Spectro-CLI based). Use it to understand conventions and to crib from `packs/` (e.g. `external-snapshotter`, `dell-csm-operator-addon`), but ship via `upload.sh` to the ISC ECR registry.
