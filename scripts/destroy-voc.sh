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
REGION="${REGION:-us-east-2}"
CLUSTER_DIR="$HOME/.vast/clusters/$CLUSTER"

# Restore the cluster's local state from the persist bucket. vastcloud's
# `cluster delete` needs ~/.vast/clusters/<name>/ (cluster.json + terraform dir)
# to recognize the cluster; a fresh CodeBuild container has none. Without this it
# reports "not found" and orphans the node. (deploy-voc.sh step 7 saved it here.)
if [[ -n "${STATE_BUCKET:-}" ]] && aws s3 ls "s3://$STATE_BUCKET/$CLUSTER/cluster.json" --region "$REGION" >/dev/null 2>&1; then
  echo "==> Restoring cluster state from s3://$STATE_BUCKET/$CLUSTER/ -> $CLUSTER_DIR"
  mkdir -p "$CLUSTER_DIR"
  aws s3 sync "s3://$STATE_BUCKET/$CLUSTER/" "$CLUSTER_DIR/" --region "$REGION"
elif [[ ! -f "$CLUSTER_DIR/cluster.json" ]]; then
  echo "==> No persisted state for '$CLUSTER' and none local — assuming already destroyed. Nothing to do."
  exit 0
fi

echo "==> Deleting cluster '$CLUSTER' via vast CLI (terminates the node, then removes its state bucket)"
"$VASTCLOUD" cluster delete "$CLUSTER" --non-interactive --force --delete-state-bucket

# Clean up the persisted copy now that the cluster is gone.
if [[ -n "${STATE_BUCKET:-}" ]]; then
  aws s3 rm "s3://$STATE_BUCKET/$CLUSTER/" --recursive --region "$REGION" >/dev/null 2>&1 || true
fi
echo "==> Cluster '$CLUSTER' deleted."

if [[ "$ALSO_NETWORK" == "1" ]]; then
  cat <<EOF

To also tear down the network (removes NAT ~\$32/mo; re-apply before next deploy):
  cd "$TF_DIR" && AWS_PROFILE=$PROFILE terraform destroy -var-file=${PROFILE}.tfvars
EOF
fi
