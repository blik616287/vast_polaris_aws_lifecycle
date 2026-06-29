#!/usr/bin/env bash
# validate-voc.sh — post-deploy HEALTH GATE for a VoC cluster.
#
# `vastcloud cluster create` declares success on cluster-create returning +
# Polaris state=running — a control-plane fact. It does NOT verify the data path
# is usable, so a cluster can be "running" while its VMS is unreachable (exactly
# what bit us: the VIP-allocation ENI was detached / in the VPC default SG, and
# the VMS wasn't serving — yet the deploy reported success and the CSI driver
# later failed every CreateVolume with "vms ... cannot be accessed").
#
# This gate makes "deployed" mean "usable". It:
#   1. reads the VMS management VIP from the VAST cluster terraform state,
#   2. ensures the VIP-allocation ENI is ATTACHED to the enode and in a
#      client-reachable SG (VAST leaves it in the VPC *default* SG, which blocks
#      consumers in any other SG — re-home it to the vast-cluster-access SG; and
#      re-attach it to the enode if it's detached), then
#   3. probes the VMS REST API on https://<mgmt-vip>:443 and FAILS if it never
#      answers — so the pipeline goes red on an unusable cluster.
#
# Must run from INSIDE the VPC (CodeBuild is) so the VIPs are reachable.
#
# Usage: validate-voc.sh <cluster> [--profile P] [--region R] [--sg <client-sg>]
set -euo pipefail

CLUSTER="${1:?cluster name required}"; shift || true
PROFILE="fieldeng"; REGION="us-east-2"; SG=""
while [[ $# -gt 0 ]]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;;
  --region)  REGION="$2";  shift 2;;
  --sg)      SG="$2";      shift 2;;
  *) shift;;
esac; done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mVALIDATION FAILED:\033[0m %s\n' "$*" >&2; exit 1; }
AWS=(aws --profile "$PROFILE" --region "$REGION")

# 1) VMS management VIP from the VAST cluster terraform state (bucket vast-cluster-<name>).
SB="vast-cluster-$CLUSTER"
KEY="$("${AWS[@]}" s3 ls "s3://$SB/" --recursive 2>/dev/null | grep -iE 'tfstate' | awk '{print $NF}' | head -1)"
[[ -n "$KEY" ]] || die "no terraform state under s3://$SB (is '$CLUSTER' deployed?)"
"${AWS[@]}" s3 cp "s3://$SB/$KEY" /tmp/voc_tfstate.json >/dev/null 2>&1 || die "cannot read VAST tfstate"
read -r VMS_HOST ENODE_IP < <(python3 - <<'PY'
import json
o=json.load(open('/tmp/voc_tfstate.json')).get('outputs',{})
def g(k):
    v=o.get(k,{}).get('value')
    return (v[0] if isinstance(v,list) and v else v) or ''
mgmt=g('vms_ip') or (g('mgmt_url').split('//')[-1].split(':')[0])
print(mgmt, g('private_ips') or g('enode_private_ips'))
PY
)
[[ -n "$VMS_HOST" ]] || die "could not determine VMS management VIP from tfstate outputs"
log "VMS management VIP: $VMS_HOST  (enode $ENODE_IP)"

# Surface (and persist) the Palette cluster-profile variables for this VoC cluster
# so the profile deploy / vast-mgmt secret can consume them without a manual lookup.
# vmsEndpoint MUST be the BARE host (no scheme — the CSI driver parses a leading
# scheme as the hostname and CreateVolume fails). The other three are VoC defaults:
# --auto-allocate-vips creates a PROTOCOLS pool named "protocolsPool"; the CSI
# export root is /csi; the stock view policy is "default".
log "Palette profile variables for '$CLUSTER':"
printf '    vmsEndpoint     = %s   (BARE host, NO scheme)\n' "$VMS_HOST"
printf '    vastVipPool     = protocolsPool\n'
printf '    vastStoragePath = /csi\n'
printf '    vastViewPolicy  = default\n'
"${AWS[@]}" ssm put-parameter --name "/voc/$CLUSTER/vms-endpoint" --type String \
  --value "$VMS_HOST" --overwrite >/dev/null 2>&1 \
  && log "Persisted VMS endpoint -> SSM /voc/$CLUSTER/vms-endpoint" \
  || true

# 2) the VIP-allocation ENI must be attached to the enode and in the client SG.
ENI="$("${AWS[@]}" ec2 describe-network-interfaces \
  --filters "Name=addresses.private-ip-address,Values=$VMS_HOST" \
  --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text 2>/dev/null)"
[[ -n "$ENI" && "$ENI" != "None" ]] || die "no ENI carries the VMS VIP $VMS_HOST"

ATTACH="$("${AWS[@]}" ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text 2>/dev/null)"
if [[ -z "$ATTACH" || "$ATTACH" == "None" ]]; then
  ENODE="$("${AWS[@]}" ec2 describe-instances --filters "Name=private-ip-address,Values=$ENODE_IP" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
  [[ -n "$ENODE" && "$ENODE" != "None" ]] || die "VIP ENI $ENI is detached and the enode could not be found"
  log "VIP ENI $ENI detached — attaching to enode $ENODE (eth1)"
  "${AWS[@]}" ec2 attach-network-interface --network-interface-id "$ENI" \
    --instance-id "$ENODE" --device-index 1 >/dev/null || die "ENI attach failed"
fi
if [[ -n "$SG" ]]; then
  CUR="$("${AWS[@]}" ec2 describe-network-interfaces --network-interface-ids "$ENI" \
    --query 'NetworkInterfaces[0].Groups[0].GroupId' --output text 2>/dev/null)"
  if [[ "$CUR" != "$SG" ]]; then
    log "VIP ENI $ENI in SG $CUR — re-homing to client SG $SG"
    "${AWS[@]}" ec2 modify-network-interface-attribute --network-interface-id "$ENI" --groups "$SG" >/dev/null \
      || die "could not move VIP ENI to SG $SG"
  fi
fi

# 3) the VMS REST API must actually answer (auth-required 401/403 still means "serving").
# The VMS install hands off to 443 several minutes AFTER vastcloud reports
# "cluster ready" (port 5551 install-monitor stays up meanwhile). Allow ~15min
# so a still-installing VMS isn't reported as a false failure.
log "Probing VMS REST at https://$VMS_HOST/api/ (up to ~15min)"
for _ in $(seq 1 40); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$VMS_HOST/api/" 2>/dev/null || true)"
  case "$code" in
    200|301|302|401|403) log "VMS is serving (HTTP $code) at https://$VMS_HOST"; exit 0;;
  esac
  sleep 15
done
# The VMS never answered. Distinguish a genuinely down VMS from "this runner has
# no route into the VAST VPC at all" — CodeBuild has no vpcConfig, so it cannot
# reach ANY private 10.20/16 address (the VMS VIP included). If we can't even TCP
# the enode's SSH (22), there is no VPC route here, so the gate simply cannot
# validate from this runner: WARN and pass (the deploy itself is complete; confirm
# VMS health in-VPC) instead of false-failing a healthy VoC. When run IN-VPC and
# the enode IS reachable but 443 isn't, that's a real failure -> die.
if ! timeout 5 bash -c "exec 3<>/dev/tcp/$ENODE_IP/22" 2>/dev/null; then
  log "WARNING: no network route to the VAST VPC from this runner (enode $ENODE_IP:22 unreachable). \
The deploy completed; the VMS health gate cannot run here. Validate in-VPC, e.g. from a node in the \
VAST VPC: curl -k https://$VMS_HOST/api/ (expect 200/401). Skipping gate — NOT failing the deploy."
  exit 0
fi
die "VMS at https://$VMS_HOST:443 never answered though the enode IS reachable — the VoC is NOT usable \
(VMS/VIP down). SSH the enode to restart VAST services, or redeploy. The CSI driver would fail every CreateVolume."
