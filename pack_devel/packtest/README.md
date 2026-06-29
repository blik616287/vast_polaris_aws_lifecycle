# packtest

Local, Docker-based validation for the VAST Data Palette packs
(`vast-csi` / `vast-cosi` / `vast-block`) — **before** publishing to ECR.

It reproduces, on a throwaway [kind](https://kind.sigs.k8s.io/) cluster, exactly
how Palette renders and installs each pack, catching the whole class of bugs that
otherwise only surface after a ~20-minute cloud cluster deploy:

- Helm template failures (e.g. `subsystem is required`, `storagePath is required`),
- missing prerequisite CRDs (`VolumeSnapshotClass`, `BucketClass`),
- value type mismatches (the `namespaceLabels` list-vs-string panic),
- bad endpoints (the COSI `exclude http//|https//` rule),
- and whether **build-on-deploy** actually works (the `fetch-runtime` init
  container crane-exporting the driver + sidecars onto `wolfi-base`).

## Usage

```bash
cd packtest
go run .                 # render + install gates for all three packs (~30s)
go run . -pods           # also run pods/build-on-deploy gate (slower, ~5 min)
go run . -keep           # leave the kind cluster up for inspection
go run . -packs vast-cosi
```

Requires `docker`, `kind`, `helm`, `kubectl` on `PATH`. Exit code is non-zero if
any gate fails, so it drops straight into CI or a pre-publish check.

## What each gate means

| gate | how | a failure means |
|------|-----|-----------------|
| **render** | `helm template` of `charts.<chart>` from the pack's `values.yaml` | the chart can't render with these values (missing required value, bad type) |
| **install** | `helm install` into the kind cluster | a CRD/admission/schema problem Palette would hit at deploy |
| **pods** (`-pods`) | wait for the `fetch-runtime` init container to exit 0 | build-on-deploy broke (crane failure, can't pull `wolfi-base`) |

The driver + CSI sidecars **crash-loop on purpose** under `-pods`: there's no real
VMS reachable from kind, and the sidecars connect to the driver's CSI socket. So
the gate only asserts the locally-testable part — that build-on-deploy completes —
and reports `driver needs real VMS` rather than failing.

## How values are derived

Palette feeds the `charts.<chart>` subtree of each pack `values.yaml` to the chart,
with `{{.spectro.var.*}}` macros filled per-cluster. packtest does the same:
it extracts that subtree from `../vast-profile/packs/<pack>-values.yaml` and
substitutes test inputs (`-vms` for the VMS host; `vippool-1`, `/csi`, etc.).
The COSI endpoint is given a bare host (the chart rejects a scheme); CSI/block
leave it empty and read it from the `vast-mgmt` secret.

## CRDs

`crds/` holds the prerequisites the charts reference, applied before any install:

- `01-volumesnapshotclass.yaml` — `snapshot.storage.k8s.io` (CSI auto-creates a `VolumeSnapshotClass`),
- `02-bucketclasses.yaml` — `objectstorage.k8s.io` (COSI creates a `BucketClass`;
  patched with the `api-approved.kubernetes.io` annotation k8s requires for the protected group).

These mirror what the cluster profile must also provide (the `external-snapshotter`
pack / a snapshot-CRD layer, and the COSI CRDs) for the packs to install in Palette.
