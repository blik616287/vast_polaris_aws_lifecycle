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
  # `aws s3 sync` does NOT preserve the executable bit. Restore +x on EVERYTHING
  # the vast CLI's `terraform destroy` execs, or it aborts and orphans resources:
  #   - provider plugins (.terraform/providers/.../terraform-provider-*) -> else
  #     "failed to instantiate provider ... fork/exec ..." (exit on schema load);
  #   - the module's SHELL SCRIPTS (e.g. scripts/download_latest_voctool.sh, run
  #     by a destroy-time local-exec) -> else exit 126 "Permission denied",
  #     aborting the destroy mid-way and leaving log groups / other resources.
  find "$CLUSTER_DIR" -type f \( -name '*.sh' -o -name 'terraform-provider-*' \) -exec chmod +x {} + 2>/dev/null || true
elif [[ ! -f "$CLUSTER_DIR/cluster.json" ]]; then
  echo "==> No persisted state for '$CLUSTER' and none local — assuming already destroyed. Nothing to do."
  exit 0
fi

# ARCHIVE the tf state bucket + cluster config for HISTORICAL RECORDS *before*
# the delete. We don't pass --delete-state-bucket, but vastcloud still removes
# s3://vast-cluster-<name> under --non-interactive — so copy it (and the persisted
# config) into a retained, timestamped archive prefix first. This is also the
# recovery record if a future destroy partially fails.
if [[ -n "${STATE_BUCKET:-}" ]]; then
  TS="$(date -u +%Y%m%d-%H%M%S)"
  ARCH="s3://$STATE_BUCKET/archive/$CLUSTER-$TS"
  echo "==> Archiving tf state + config for records -> $ARCH/"
  aws s3 sync "s3://vast-cluster-$CLUSTER/" "$ARCH/tfstate/" --region "$REGION" >/dev/null 2>&1 || true
  aws s3 sync "s3://$STATE_BUCKET/$CLUSTER/" "$ARCH/config/"  --region "$REGION" >/dev/null 2>&1 || true
fi

echo "==> Deleting cluster '$CLUSTER' via vast CLI (destroys the cluster's AWS resources)"
"$VASTCLOUD" cluster delete "$CLUSTER" --non-interactive --force

# The node's CloudWatch agent auto-creates "<cluster>-log-group-<id>", which is NOT
# in the cluster's terraform state — so `terraform destroy` leaves it behind (one
# accumulates per deploy). Clean it for a complete teardown.
for lg in $(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "${CLUSTER}-log-group" \
    --query 'logGroups[].logGroupName' --output text 2>/dev/null); do
  aws logs delete-log-group --region "$REGION" --log-group-name "$lg" 2>/dev/null \
    && echo "    cleaned node CloudWatch log group $lg"
done

# Post-delete VERIFICATION (don't trust the vast CLI's exit code — it ran under
# --force and has silently left orphans before). FAIL LOUDLY if billing-capable
# resources survived, so a partial teardown is never reported as success.
echo "==> Verifying clean teardown"
LEFT_INST="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:cluster_name,Values=$CLUSTER" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)"
if [[ "${LEFT_INST:-0}" != "0" ]]; then
  echo "ERROR: teardown left $LEFT_INST instance(s) for '$CLUSTER' — NOT a clean delete." >&2; exit 1
fi
echo "    no surviving instances for '$CLUSTER'"

echo "==> Cluster '$CLUSTER' destroyed. Retained for records:"
echo "      tf state : s3://vast-cluster-$CLUSTER/"
[[ -n "${STATE_BUCKET:-}" ]] && echo "      config   : s3://$STATE_BUCKET/$CLUSTER/"

if [[ "$ALSO_NETWORK" == "1" ]]; then
  cat <<EOF

To also tear down the network (removes NAT ~\$32/mo; re-apply before next deploy):
  cd "$TF_DIR" && AWS_PROFILE=$PROFILE terraform destroy -var-file=${PROFILE}.tfvars
EOF
fi
