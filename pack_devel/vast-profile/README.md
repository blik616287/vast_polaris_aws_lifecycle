# vast-profile

A Go tool (modeled on `../cmargo/cluster-profile`) that builds and publishes a
**Palette cluster profile carrying the three VAST Data add-on packs**
(`vast-csi` / `vast-cosi` / `vast-block`) via `palette-sdk-go`, with the VMS
connection details exposed as **sensitive profile variables** filled per-cluster
at deploy time — never baked into the published profile.

Pack UIDs are **resolved from the registry by name** (not hardcoded), so the only
prerequisite is that `../upload.sh` has pushed the packs and Palette has synced
them.

## Layout

```
vast-profile/
├── cmd/create-profile/main.go   # resolves VAST pack UIDs + publishes the profile
├── cmd/deploy-cluster/main.go   # binds the profile to an AWS cluster + fills VMS vars
├── packs/                       # full values.yaml per pack, VMS fields wired to {{.spectro.var.*}}
│   ├── vast-csi-values.yaml
│   ├── vast-cosi-values.yaml
│   └── vast-block-values.yaml
├── manifests/
│   └── vast-mgmt-secret.yaml    # vast-mgmt Secret (+ namespaces) from Palette vars
├── go.mod / go.sum              # uses palette-sdk-go via a replace directive
└── README.md
```

## Build / run

```bash
# The SDK is consumed via a replace directive (see go.mod). Point it at a local
# checkout of github.com/spectrocloud/palette-sdk-go (cmargo uses /tmp/palette-sdk-go).
go build ./...

# Default: a portable add-on profile (cloudType "all") = the 3 VAST packs + the
# vast-mgmt secret. Attach it onto any AWS/EKS cluster profile.
PALETTE_API_KEY=<token> go run ./cmd/create-profile

# Full AWS cluster profile (infra stack + VAST packs):
PALETTE_API_KEY=<token> PROFILE_TYPE=cluster go run ./cmd/create-profile

# Provision a managed AWS cluster bound to the profile, filling the VMS variables.
# Resolves the newest published `vast-storage` profile unless PROFILE_UID is set.
PALETTE_API_KEY=<token> \
  CLOUD_ACCOUNT=<aws-account-name-in-palette> SSH_KEY_NAME=<ec2-keypair> \
  VPC_ID=<peered-vpc> AZS=us-east-2a SUBNET_IDS=<subnet-in-2a> \
  VMS_ENDPOINT=https://<VMS-VIP> VMS_USERNAME=<u> VMS_PASSWORD=<p> \
  VAST_VIP_POOL=<pool> VAST_STORAGE_PATH=/k8s/tenant-a \
  go run ./cmd/deploy-cluster
```

### Key env vars

| Var | Default | Purpose |
|---|---|---|
| `PALETTE_API_KEY` | — (required) | API key for `palette.isc-spectro-dev.click` |
| `PROFILE_TYPE` | `add-on` | `add-on` (VAST packs only) or `cluster` (AWS infra + VAST) |
| `PROFILE_NAME` | `vast-storage` | Cluster-profile name (patch auto-increments per run) |
| `ISC_REGISTRY_UID` | `6a29d1b56365d069e5ac1d81` | ISC pack registry holding the VAST packs (from `../upload.sh`) |
| `PALETTE_PROJECT` | — | Project UID to scope to (optional) |
| `PUBLIC_REGISTRY` / `INFRA_*_NAME`/`_TAG` | `Public Repo`, defaults | AWS infra layer resolution in `cluster` mode |

## How it works

1. Resolve the ISC registry UID (constant default, or by name via `GetPackRegistryByName`).
2. For each VAST layer, `GetPacksByNameAndRegistry(name, registryUID)` → pick the
   requested tag (`2.6.5`) → its `packUid`. Values come from `packs/*.yaml`
   (the full pack `values.yaml` with VMS fields templated as `{{.spectro.var.*}}`).
3. Add a manifest-only layer for the `vast-mgmt` Secret (sourced from the same vars).
4. Declare the VMS profile variables (sensitive: username/password/qos), then
   `CreateClusterProfile` + `PublishClusterProfile`. `nextVersion` auto-bumps the patch.

### Profile variables

`vmsEndpoint`, `vmsUsername`*, `vmsPassword`*, `vastVipPool`, `vastStoragePath`,
`vastViewPolicy`, `vastQosPolicy`*  (`*` = sensitive). These feed both the pack
values and the `vast-mgmt` Secret, so the VMS VIP + credentials live only in the
encrypted per-cluster variable values. Per-tenant overrides (VIP pool / QoS) map
directly to the Phase-2 multi-tenancy plan.

## Notes

- The VAST CSI node DaemonSet needs **privileged** pods; the pack values + the
  secret manifest label each namespace `pod-security.kubernetes.io/enforce=privileged`.
- The cluster VPC must peer to the VAST VPC (account `fieldeng`) so the driver can
  reach the VMS VIP — pass `VPC_ID` + `SUBNET_IDS`/`AZS` of the peered subnets to
  `deploy-cluster`. See `../../README.md` / `../../../SCOPING.md`.

### deploy-cluster

`cmd/deploy-cluster` (modeled on cmargo's deploy-cluster, adapted edge→AWS) resolves
the AWS cloud account + the published profile, optionally deletes a same-named cluster
(`REDEPLOY=1`), then `CreateClusterAws` with a control-plane + worker machine pool and
the VMS variable **values** (`VMS_*` / `VAST_*` env → the profile's `{{.spectro.var.*}}`).
The worker pool should sit in the VIP pool's AZ(s) so the data path stays same-AZ. The
sensitive VMS password is supplied here, per-cluster — never stored in the profile.
