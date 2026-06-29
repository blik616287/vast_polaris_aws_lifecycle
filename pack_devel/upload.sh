#!/bin/bash
# Push VSS Palette packs to the ISC Palette Registry AND verify the full round-trip:
#   push (oras) -> verify artifact in ECR -> trigger Palette registry sync ->
#   poll until the pack+version appears in Palette's catalog -> validate the pack.
#
# The ISC Palette Registry is an ECR-backed pack registry:
#   216938125181.dkr.ecr.us-east-2.amazonaws.com  (account 216938125181, us-east-2)
# reachable via the `spectro` AWS profile. Packs land at the path Palette scans:
#   <REGISTRY_NAME>/spectro-packs/archive/<packName>:<version>
# Packs that share a name (e.g. nvidia-vss-data-infrastructure 2.4.3 + 3.1.0) push as
# separate VERSION TAGS of the same pack repo automatically (repo=name, tag=version).
#
# Usage:
#   PALETTE_APIKEY=<key> ./upload.sh                 # all nvidia-vss-* pack dirs
#   PALETTE_APIKEY=<key> ./upload.sh <dir>...        # specific dirs
# Env overrides: AWS_PROFILE, AWS_REGION, REGISTRY_NAME, PALETTE_API, PALETTE_REG_UID,
#                ORAS_CONFIG, SYNC_TIMEOUT (seconds), SKIP_SYNC=1 (push+verify only).

set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin:${PATH:-}

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; clear='\033[0m'

# --- config ---
AWS_PROFILE="${AWS_PROFILE:-spectro}"
AWS_REGION="${AWS_REGION:-us-east-2}"
REGISTRY_NAME="${REGISTRY_NAME:-spectro-packs}"
ORAS_CONFIG="${ORAS_CONFIG:-$HOME/.oras/auth.json}"
PALETTE_API="${PALETTE_API:-https://default.palette.isc-spectro-dev.click}"
PALETTE_REG_UID="${PALETTE_REG_UID:-6a29d1b56365d069e5ac1d81}"   # ISC Palette Registry
PALETTE_APIKEY="${PALETTE_APIKEY:-}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-360}"
SKIP_SYNC="${SKIP_SYNC:-0}"
mkdir -p "$(dirname "$ORAS_CONFIG")"

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
pal() { # pal METHOD PATH  -> body on stdout
  curl -s -X "$1" -H "ApiKey: $PALETTE_APIKEY" -H "Accept: application/json" -H "Content-Type: application/json" "$PALETTE_API$2"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$ROOT"

# --- resolve pack dirs ---
declare -a PACKS=()
if [ "$#" -gt 0 ]; then PACKS=("$@")
elif [ -f pack.json ]; then PACKS=("$(basename "$PWD")"); cd ..; ROOT="$PWD"
else for d in */ ; do [ -f "${d}pack.json" ] && PACKS+=("${d%/}"); done; fi
[ "${#PACKS[@]}" -eq 0 ] && { echo -e "${red}No pack dirs found.${clear}"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ENDPOINT="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BASE="${REGISTRY_NAME}/spectro-packs/archive"
echo -e "Target: ${yellow}${ENDPOINT}/${BASE}${clear} (profile ${yellow}${AWS_PROFILE}${clear})  | Palette reg ${yellow}${PALETTE_REG_UID}${clear}"
echo -e "Packs:  ${yellow}${PACKS[*]}${clear}"
[ "$SKIP_SYNC" = "0" ] && [ -z "$PALETTE_APIKEY" ] && { echo -e "${red}PALETTE_APIKEY not set (needed for sync/verify). Set it or run SKIP_SYNC=1.${clear}"; exit 1; }

aws ecr get-login-password | oras login --username AWS --password-stdin --registry-config "$ORAS_CONFIG" "$ENDPOINT"

push_pack() {
  local dir="${1%/}" name version expected tarball repo
  [ -f "$dir/pack.json" ] || { echo -e "${red}skip ${dir}: no pack.json${clear}"; return 1; }
  name="$(jq -r .name "$dir/pack.json")"; version="$(jq -r .version "$dir/pack.json")"
  expected="${name}-${version}"
  [ "$(basename "$dir")" = "$expected" ] || { echo -e "${red}skip ${dir}: dir basename must be <name>-<version> (${expected})${clear}"; return 1; }
  tarball="${expected}.tar.gz"; repo="${BASE}/${name}"
  echo -e "\n=== ${yellow}${name}:${version}${clear} ==="

  # 1) package + push. The OCI layer TITLE must be the bare "<name>-<version>.tar.gz"
  # (Palette's pack scanner keys off it) — so build the tarball at root and push it by
  # its bare name, NOT a dir-prefixed path.
  rm -f "$tarball"; tar -czf "$tarball" -C "$(dirname "$dir")" "$(basename "$dir")"
  aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$repo" >/dev/null
  oras push --registry-config "$ORAS_CONFIG" "${ENDPOINT}/${repo}:${version}" "$tarball" >/dev/null
  rm -f "$tarball"
  echo -e "  ${green}pushed${clear} ${ENDPOINT}/${repo}:${version}"

  # 2) verify the artifact actually landed in ECR
  if oras manifest fetch --registry-config "$ORAS_CONFIG" "${ENDPOINT}/${repo}:${version}" >/dev/null 2>&1; then
    echo -e "  ${green}verified${clear} artifact present in registry (oras manifest fetch OK)"
  else
    echo -e "  ${red}PUSH VERIFY FAILED${clear}: manifest not fetchable"; return 1
  fi
  [ "$SKIP_SYNC" = "1" ] && return 0

  # 3) trigger the registry sync. This is an ECR-backed OCI registry, so it uses
  # the /ecr/ sync endpoint (the /basic/ variant is for basic-auth OCI registries
  # and 404s "Resource not found" against an ECR registry). Verified -> HTTP 202.
  pal POST "/v1/registries/oci/${PALETTE_REG_UID}/ecr/sync" >/dev/null
  echo -e "  sync triggered; polling Palette catalog (timeout ${SYNC_TIMEOUT}s)..."

  # 4) poll Palette catalog until the version tag appears (= sync complete + indexed)
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT )) found="" body
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$(pal GET "/v1/packs/${name}/registries/${PALETTE_REG_UID}")"
    found="$(printf '%s' "$body" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
tags=[t.get('tag') for t in (d.get('tags') or [])]
print('yes' if '${version}' in tags else '')
" 2>/dev/null)"
    [ "$found" = "yes" ] && break
    sleep 10
  done

  # 5) validate the synced pack
  if [ "$found" = "yes" ]; then
    printf '%s' "$body" | python3 -c "
import sys,json
d=json.load(sys.stdin)
tag='${version}'; name='${name}'
t=[x for x in (d.get('tags') or []) if x.get('tag')==tag][0]
puid=t.get('packUid')
pv=[v for v in (d.get('packValues') or []) if v.get('packUid')==puid]
layer=d.get('layer'); ok = bool(pv) and bool((pv[0].get('values') if pv else ''))
print('  ${green}VALID${clear} in Palette: %s:%s  layer=%s packUid=%s values=%s' % (name,tag,layer,puid,'present' if ok else 'EMPTY'))
import sys as s
s.exit(0 if ok else 2)
" || { echo -e "  ${red}VALIDATION WARNING${clear}: pack present but values empty"; return 1; }
  else
    echo -e "  ${red}SYNC TIMEOUT${clear}: ${name}:${version} not in Palette catalog after ${SYNC_TIMEOUT}s"; return 1
  fi
}

rc=0
for d in "${PACKS[@]}"; do push_pack "$d" || rc=1; done
echo -e "\n$([ $rc -eq 0 ] && echo -e "${green}ALL PACKS PUSHED + VERIFIED + VALID IN PALETTE${clear}" || echo -e "${red}SOME PACKS FAILED (see above)${clear}")"
exit $rc
