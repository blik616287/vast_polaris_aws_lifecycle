#!/usr/bin/env bash
# polaris-register.sh — register a PENDING VoC cluster in Polaris via the Polaris
# Platform API, so that `vastcloud cluster create --select` deploys it WITH a PIN
# (the node authenticates to Polaris and runs `configure_cloud_resources`).
#
# WHY: bare `vastcloud cluster create` (no pending cluster / PIN) provisions the
# node, but its bootstrap runs `polaris_agent_install_and_auth --skip-polaris` and
# then dies with `FileNotFoundError: 'configure_cloud_resources'` — so the VMS
# never installs and nothing serves on 443/5551. The documented, working VoC deploy
# uses a Polaris deployment (web portal / CloudFormation) that yields a PIN. This
# script does the same thing headlessly via the API the portal uses.
#
# Discovered from the Polaris OpenAPI spec
# (GET https://api.aws.polaris.vastdata.com/swagger/openapi.json — "Polaris Platform API"):
#   GET  .../providers/VAST.Data/entitlements?api-version=2025-09-01      -> entitlementId
#   PUT  .../providers/VAST.Data/clusters/{name}?api-version=2025-09-01   -> create pending cluster
#   (the PIN itself is minted by `vastcloud --select` calling :generatePin)
#
# Usage: polaris-register.sh <name> --region R [--zone Z] [--nodes N] [--instance-type T]
# Requires: a prior `vastcloud login` (token cached under ~/.vast/accounts/*/token.json),
#           AWS creds for the deployment account (subscription == AWS account-id).
set -euo pipefail

NAME="${1:?cluster name required}"; shift || true
# instanceType is REQUIRED in the pending cluster: `vastcloud create --select`
# reads the config from it and fails "instance type not found" if absent. Default
# to the VoC AWS minimum (i3en.24xlarge); override with --instance-type.
REGION="us-east-2"; ZONE=""; NODES="1"; ITYPE="i3en.24xlarge"; STORAGE_TB="${STORAGE_TB:-}"
while [[ $# -gt 0 ]]; do case "$1" in
  --region) REGION="$2"; shift 2;;
  --zone) ZONE="$2"; shift 2;;
  --nodes) NODES="$2"; shift 2;;
  --instance-type) ITYPE="$2"; shift 2;;
  *) shift;;
esac; done
[[ -z "$ZONE" ]] && ZONE="${REGION}a"

API="${POLARIS_API:-https://api.aws.polaris.vastdata.com}"
AV="${POLARIS_API_VERSION:-2025-09-01}"
RG="${POLARIS_RESOURCE_GROUP:-default}"
SUB="$(aws sts get-caller-identity --query Account --output text)"
TOKFILE="$(ls -t "$HOME"/.vast/accounts/*/token.json 2>/dev/null | head -1)"
[[ -n "$TOKFILE" ]] || { echo "polaris-register: no cached token (run 'vastcloud login' first)" >&2; exit 1; }
TOK="$(python3 -c "import json;print(json.load(open('$TOKFILE'))['access_token'])")"

BASE="$API/subscriptions/$SUB/resourceGroups/$RG/providers/VAST.Data"
auth=(-H "Authorization: Bearer $TOK" -H "Content-Type: application/json")

# 1) resolve the active entitlement (required by the cluster create body).
ENT="$(curl -s --max-time 20 "${auth[@]}" "$BASE/entitlements?api-version=$AV" \
  | python3 -c "import json,sys
v=json.load(sys.stdin).get('value',[])
act=[e for e in v if e.get('properties',{}).get('status')=='Active'] or v
print(act[0]['id'] if act else '')")"
[[ -n "$ENT" ]] || { echo "polaris-register: no VAST entitlement found for subscription $SUB" >&2; exit 1; }

# 2) PUT the pending cluster (idempotent create-or-update). instanceType/storageTB
# are optional; omit instanceType to let VoC pick its supported default.
BODY="$(python3 -c "
import json
p={'cloud':'AWS','region':'$REGION','zone':'$ZONE','registrationType':'customer-created',
   'state':'Pending','entitlementId':'$ENT','nodeCount':int('$NODES')}
if '$ITYPE': p['instanceType']='$ITYPE'
if '$STORAGE_TB': p['storageTB']=float('$STORAGE_TB')
print(json.dumps({'name':'$NAME','type':'VAST.Data/clusters','location':'global','properties':p}))")"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X PUT "${auth[@]}" \
  --data "$BODY" "$BASE/clusters/$NAME?api-version=$AV")"
case "$code" in
  200|201) echo "polaris-register: pending cluster '$NAME' registered in Polaris (HTTP $code, entitlement ${ENT##*/})";;
  *) echo "polaris-register: PUT cluster failed (HTTP $code)" >&2; exit 1;;
esac
