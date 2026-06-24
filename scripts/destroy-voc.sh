#!/usr/bin/env bash
# =============================================================================
# destroy-voc.sh — delete a VoC cluster to stop billing.
# The clean way to "pause" a VoC cluster: delete it (do NOT `aws ec2 stop` an
# i3en node — its instance-store NVMe is wiped on stop and VAST isn't designed
# to be EC2-stopped). Redeploy takes ~10 min with deploy-voc.sh.
#
# Usage: scripts/destroy-voc.sh <cluster-name> [--profile fieldeng]
# Leaves the terraform network in place (NAT ~$32/mo). Add --network to also
# print the command to destroy the network for true-zero cost.
# =============================================================================
set -euo pipefail
CLUSTER="${1:-}"; shift || true
PROFILE="fieldeng"; ALSO_NETWORK="0"
VASTCLOUD="${VASTCLOUD:-vastcloud}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" 2>/dev/null && pwd || true)"
[[ -z "$CLUSTER" ]] && { echo "usage: $0 <cluster-name> [--profile P] [--network]"; exit 1; }
while [[ $# -gt 0 ]]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;;
  --network) ALSO_NETWORK="1"; shift;;
  *) echo "unknown arg: $1"; exit 1;; esac; done
export AWS_PROFILE="$PROFILE"

# Discover the cluster from its vast-cluster-* S3 bucket — a fresh CodeBuild
# container has no local ~/.vast state, so without this `cluster delete` reports
# "not found" and the node orphans. This populates vastcloud so delete can run.
echo "==> Discovering cluster '$CLUSTER' from S3 (orphaned/not-locally-tracked)"
"$VASTCLOUD" cluster list --include-bucket-discovery --non-interactive >/dev/null 2>&1 || true

# Idempotent: if the cluster isn't discoverable, it's already gone -> success.
if ! "$VASTCLOUD" cluster list --include-bucket-discovery --non-interactive --output json 2>/dev/null \
     | python3 -c "import sys,json
d=json.load(sys.stdin) or []
sys.exit(0 if ('$CLUSTER' in json.dumps(d)) else 1)"; then
  echo "==> Cluster '$CLUSTER' not found — already destroyed. Nothing to do."
  exit 0
fi

echo "==> Deleting cluster '$CLUSTER' via vast CLI (terminates the node, removes state bucket)"
"$VASTCLOUD" cluster delete "$CLUSTER" --non-interactive --force --delete-state-bucket

echo "==> Post-delete cluster list"
"$VASTCLOUD" cluster list --include-bucket-discovery || true

if [[ "$ALSO_NETWORK" == "1" ]]; then
  cat <<EOF

To also tear down the network (removes NAT ~\$32/mo; re-apply before next deploy):
  cd "$TF_DIR" && AWS_PROFILE=$PROFILE terraform destroy -var-file=${PROFILE}.tfvars
EOF
fi
