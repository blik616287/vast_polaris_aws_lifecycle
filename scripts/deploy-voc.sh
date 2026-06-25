#!/usr/bin/env bash
# =============================================================================
# deploy-voc.sh — generate a VAST on Cloud (VoC) cluster on AWS.
#
# Encodes every lesson from the first bring-up so a deploy "just works":
#   1. ensures the vastcloud CLI is installed
#   2. ensures Polaris login + config point at the right AWS profile/endpoint
#   3. pre-creates the cluster key pair (create's pre-checker requires it to exist)
#   4. clears any stale cluster record of the same name (failed attempts leave one)
#   5. reads subnet/SG from terraform outputs (or flags)
#   6. runs `vastcloud cluster create` (lets VoC pick the supported instance type)
#
# Usage:
#   scripts/deploy-voc.sh <cluster-name> [--profile fieldeng] [--region us-east-2]
#                         [--subnet subnet-xxx] [--sg sg-xxx] [--zone us-east-2a]
#                         [--nodes 1] [--instance-type i3en.24xlarge] [--no-preflight]
#
# With no --subnet/--sg, it reads them from ../terraform outputs (terraform output -json).
# =============================================================================
set -euo pipefail

# ---- defaults ----
CLUSTER="${1:-}"; shift || true
PROFILE="fieldeng"
REGION="us-east-2"
ZONE=""
SUBNET=""
SG=""
NODES="1"
INSTANCE_TYPE=""           # empty => VoC default (i3en.24xlarge minimum; smaller is unsupported)
RUN_PREFLIGHT="1"
# Only needed as a fallback to read subnet/SG from terraform outputs. In CodeBuild
# the artifact has no terraform/ dir (subnet/SG are passed as flags), so tolerate absence.
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" 2>/dev/null && pwd || true)"
VASTCLOUD="${VASTCLOUD:-vastcloud}"
POLARIS_ENDPOINT="https://api.aws.polaris.vastdata.com"

usage() { sed -n '2,20p' "$0"; exit 1; }
[[ -z "$CLUSTER" ]] && { echo "ERROR: cluster name required"; usage; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --zone) ZONE="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --sg) SG="$2"; shift 2;;
    --nodes) NODES="$2"; shift 2;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2;;
    --no-preflight) RUN_PREFLIGHT="0"; shift;;
    *) echo "unknown arg: $1"; usage;;
  esac
done
export AWS_PROFILE="$PROFILE"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. vastcloud CLI ----
if ! command -v "$VASTCLOUD" >/dev/null 2>&1; then
  if [[ -x "$VASTCLOUD" ]]; then :; else
    log "Installing vastcloud CLI to ./bin"
    mkdir -p "$(dirname "${BASH_SOURCE[0]}")/bin"
    BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/vastcloud"
    os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); [[ "$arch" == "x86_64" ]] && arch=amd64; [[ "$arch" == "aarch64" ]] && arch=arm64
    curl -fL --progress-bar "https://storage.googleapis.com/polaris-vastcloud/${os}-${arch}/vastcloud" -o "$BIN"
    chmod +x "$BIN"; VASTCLOUD="$BIN"
  fi
fi
log "vastcloud: $VASTCLOUD"

# ---- 2. config + login ----
if ! "$VASTCLOUD" config current-context >/dev/null 2>&1; then
  log "Initializing vastcloud config (provider aws, profile $PROFILE, $POLARIS_ENDPOINT)"
  "$VASTCLOUD" config init --non-interactive --provider aws --aws-region "$REGION" \
    --aws-profile "$PROFILE" --endpoint "$POLARIS_ENDPOINT" --account-name "$PROFILE" --force
fi
if ! "$VASTCLOUD" auth status >/dev/null 2>&1; then
  if [[ -n "${POLARIS_USERNAME:-}" && -n "${POLARIS_PASSWORD:-}" ]]; then
    log "Polaris login (non-interactive, as $POLARIS_USERNAME)"
    printf '%s' "$POLARIS_PASSWORD" | "$VASTCLOUD" login --username "$POLARIS_USERNAME" --password-stdin \
      || die "Polaris password login failed"
  else
    log "Polaris login required (set POLARIS_USERNAME/POLARIS_PASSWORD for CI, or login interactively)"
    "$VASTCLOUD" login || die "Polaris login failed"
  fi
fi
"$VASTCLOUD" auth status | sed -n '1,4p' || true

# ---- 3. resolve subnet/SG/zone from terraform outputs if not given ----
if [[ -z "$SUBNET" || -z "$SG" ]]; then
  log "Reading subnet/SG from terraform outputs in $TF_DIR"
  command -v terraform >/dev/null || die "terraform not found and --subnet/--sg not given"
  TFOUT="$(terraform -chdir="$TF_DIR" output -json 2>/dev/null || true)"
  [[ -z "$TFOUT" || "$TFOUT" == "{}" ]] && die "no terraform outputs — run 'terraform apply' first, or pass --subnet/--sg"
  [[ -z "$SUBNET" ]] && SUBNET="$(echo "$TFOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["deploy_subnet_id"]["value"])')"
  [[ -z "$SG"     ]] && SG="$(echo "$TFOUT"     | python3 -c 'import json,sys;print(json.load(sys.stdin)["vast_cluster_access_sg_id"]["value"])')"
  [[ -z "$ZONE"   ]] && ZONE="$(echo "$TFOUT"   | python3 -c 'import json,sys;print(json.load(sys.stdin)["deploy_zone"]["value"])')"
fi
[[ -z "$ZONE" ]] && ZONE="${REGION}a"
log "Target: subnet=$SUBNET  sg=$SG  zone=$ZONE  nodes=$NODES  instance=${INSTANCE_TYPE:-<VoC default>}"

# ---- 4. key pair (create's pre-checker requires <cluster>-vastdata-cluster-key to EXIST) ----
KN="${CLUSTER}-vastdata-cluster-key"
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KN" >/dev/null 2>&1; then
  PEM="$HOME/.vast/${KN}.pem"; mkdir -p "$HOME/.vast"
  log "Creating key pair $KN (PEM -> $PEM)"
  aws ec2 create-key-pair --region "$REGION" --key-name "$KN" --query KeyMaterial --output text > "$PEM"
  chmod 600 "$PEM"
else
  log "Key pair $KN already exists"
fi

# ---- 5. idempotency: a deploy must never rebuild an existing cluster ----
# vastcloud's local ~/.vast state is empty in a fresh container, so we use the
# persisted cluster state in STATE_BUCKET (saved by a previous deploy, step 7)
# as the source of truth, plus a running-instance tag check as a backstop.
CLUSTER_DIR="$HOME/.vast/clusters/$CLUSTER"
if [[ -n "${STATE_BUCKET:-}" ]] && aws s3 ls "s3://$STATE_BUCKET/$CLUSTER/cluster.json" --region "$REGION" >/dev/null 2>&1; then
  log "Cluster '$CLUSTER' already deployed (state in s3://$STATE_BUCKET/$CLUSTER/) — deploy is a no-op."
  exit 0
fi
if aws ec2 describe-instances --region "$REGION" \
     --filters "Name=tag:cluster_name,Values=${CLUSTER}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
     --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | grep -q .; then
  log "Cluster '$CLUSTER' already has running instances — deploy is a no-op."
  exit 0
fi

# ---- 6. create ----
ARGS=(cluster create "$CLUSTER" --provider aws --region "$REGION" --zone "$ZONE"
      --subnet "$SUBNET" --aws-security-group-ids "$SG"
      --nodes "$NODES" --auto-allocate-vips --non-interactive --force)
[[ -n "$INSTANCE_TYPE" ]] && ARGS+=(--instance-type "$INSTANCE_TYPE")
[[ "$RUN_PREFLIGHT" == "0" ]] && ARGS+=(--skip-checker)

log "Creating cluster (this provisions a real i3en.24xlarge node — ~\$10.85/hr until deleted)"
echo "    $VASTCLOUD ${ARGS[*]}"
"$VASTCLOUD" "${ARGS[@]}"

# ---- 7. persist the cluster's local state so a future (ephemeral) destroy build
# can restore it and run `vastcloud cluster delete`. This is the key to making the
# vast-CLI delete work across containers: vastcloud needs ~/.vast/clusters/<name>/
# (cluster.json + terraform dir) to recognize the cluster. ----
if [[ -n "${STATE_BUCKET:-}" && -d "$CLUSTER_DIR" ]]; then
  log "Persisting cluster state -> s3://$STATE_BUCKET/$CLUSTER/"
  aws s3 sync "$CLUSTER_DIR/" "s3://$STATE_BUCKET/$CLUSTER/" --region "$REGION" --delete
fi

log "Done. Cluster info:"
# Informational only — the cluster is already created/ready above. Don't fail the
# build if the Polaris token has expired by now on a long deploy.
"$VASTCLOUD" cluster list || true
cat <<EOF

Next:
  - VMS / Management URL is shown above (https://<VMS-VIP>); reachable from inside
    the VAST VPC or a peered VPC, NOT from your laptop. Rotate the default admin/123456.
  - Configure tenant/VIP-pool/QoS/view via terraform/vast-tenancy (point it at the VMS VIP).
  - Tear down to stop billing:  scripts/destroy-voc.sh $CLUSTER --profile $PROFILE
EOF
