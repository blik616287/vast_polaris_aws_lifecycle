#!/usr/bin/env bash
# =============================================================================
# tenant-voc.sh — imperative, idempotent VAST multi-tenancy setup via the VMS
# REST API. Same paradigm as the deploy stage (deploy-voc.sh / vastcloud): direct
# API calls in CodeBuild, NO terraform and NO state store.
#
# Idempotent by construction: every object is GET-by-name (or by-path) first and
# only POSTed if absent. Re-running is a no-op; adding a tenant to tenants.json
# and re-running creates only the new objects.
#
# Runs as the `tenant` ACTION of the lifecycle CodeBuild (VPC-attached, so the VMS
# VIP is directly reachable), or from any host with a route to the VMS.
# VMS_USERNAME/VMS_PASSWORD come from Secrets Manager (vast/vms-admin) as env vars.
# =============================================================================
set -euo pipefail

CFG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tenants.json}"
# VMS VIP: prefer an explicit VMS_HOST, else the endpoint validate-voc.sh persisted
# to SSM after the VoC deploy (so this auto-targets a freshly redeployed VoC), else
# the well-known default. CLUSTER_NAME comes from deploy.env in CodeBuild.
: "${CLUSTER_NAME:=voc-fieldeng}"
if [ -z "${VMS_HOST:-}" ]; then
  VMS_HOST=$(aws ssm get-parameter --name "/voc/${CLUSTER_NAME}/vms-endpoint" \
    --region "${AWS_REGION:-${REGION:-us-east-2}}" --query 'Parameter.Value' --output text 2>/dev/null || true)
fi
VMS_HOST="${VMS_HOST:-10.20.9.141}"
VMS="https://${VMS_HOST}:${VMS_PORT:-443}/api"
: "${VMS_USERNAME:?VMS_USERNAME required (Secrets Manager vast/vms-admin:username)}"
: "${VMS_PASSWORD:?VMS_PASSWORD required (Secrets Manager vast/vms-admin:password)}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

TOKEN=$(curl -sk -X POST "$VMS/token/" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$VMS_USERNAME\",\"password\":\"$VMS_PASSWORD\"}" | jq -r '.access // empty')
[ -n "$TOKEN" ] || { echo "ERROR: VMS auth failed" >&2; exit 1; }

g() { curl -sk -H "Authorization: Bearer $TOKEN" "$VMS/$1"; }
post() { curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "$VMS/$1" -d "$2"; }

# ensure <endpoint> <query> <create-body> [label]  -> echoes the object id.
# GET by the query first; create only if not present (idempotent).
ensure() {
  local ep="$1" query="$2" body="$3" label="${4:-$ep}"
  # Array-safe lookup: the VMS returns either a bare array or {results:[...]}.
  # NOTE: a naive '.[0].id // .results[0].id' errors on an EMPTY array (the
  # fallback evaluates .results against an array), aborting under pipefail.
  local id
  id=$(g "${ep}/?${query}" 2>/dev/null | jq -r '(if type=="array" then .[0] else .results[0] end | .id) // empty' 2>/dev/null || true)
  if [ -n "$id" ]; then echo "    = $label exists (id=$id)" >&2; echo "$id"; return; fi
  # Retry transient failures: a freshly-deployed VMS answers its REST API (200)
  # several minutes before its data-write services accept writes, so the first
  # creates can fail with a connection error. Retry up to ~60s before giving up.
  local resp tries=0
  while [ "$tries" -lt 6 ]; do
    resp=$(post "${ep}/" "$body" 2>/dev/null || true)
    id=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$id" ] && break
    tries=$((tries + 1))
    echo "    ~ $label not ready yet, retry $tries/6..." >&2
    sleep 10
  done
  [ -n "$id" ] || { echo "    ! $label create failed: $(printf '%s' "$resp" | jq -rc '.detail // .' 2>/dev/null)" >&2; exit 1; }
  echo "    + $label created (id=$id)" >&2; echo "$id"
}

QTIERS=$(jq -c '.qos_tiers' "$CFG")
jq -c '.tenants[]' "$CFG" | while read -r t; do
  name=$(jq -r '.name' <<<"$t")
  tier=$(jq -r '.qos_tier' <<<"$t")
  q=$(jq -c --argjson q "$QTIERS" --arg k "$tier" '$q[$k]' <<<'{}')
  log "tenant '$name' (qos=$tier)"

  tid=$(ensure tenants "name=$name" \
    "$(jq -c '{name:.name, client_ip_ranges:.client_ip_ranges}' <<<"$t")" "tenant")

  ensure vippools "name=${name}-pool" \
    "$(jq -c --argjson tid "$tid" --arg n "${name}-pool" \
      '{name:$n, role:"PROTOCOLS", subnet_cidr:.subnet_cidr, ip_ranges:.vip_ip_ranges, tenant_id:$tid}' <<<"$t")" "vip-pool" >/dev/null

  qid=$(ensure qospolicies "name=${name}-${tier}" \
    "$(jq -c --argjson tid "$tid" --argjson q "$q" --arg n "${name}-${tier}" \
      '{name:$n, policy_type:"VIEW", limit_by:"BW_IOPS", is_gold:$q.is_gold, tenant_id:$tid,
        static_limits:{max_reads_bw_mbps:$q.max_reads_bw_mbps, max_writes_bw_mbps:$q.max_writes_bw_mbps,
        max_reads_iops:$q.max_reads_iops, max_writes_iops:$q.max_writes_iops}}' <<<"$t")" "qos")

  pid=$(ensure viewpolicies "name=${name}-policy" \
    "$(jq -c --argjson tid "$tid" --arg n "${name}-policy" \
      '{name:$n, flavor:"NFS", nfs_read_write:.nfs_read_write, tenant_id:$tid}' <<<"$t")" "view-policy")

  path=$(jq -r '.storage_path' <<<"$t")
  ensure views "path=${path}" \
    "$(jq -c --argjson tid "$tid" --argjson pid "$pid" --argjson qid "$qid" --arg p "$path" \
      '{path:$p, policy_id:$pid, tenant_id:$tid, qos_policy_id:$qid, protocols:["NFS"], create_dir:true}' <<<"$t")" "nfs-view" >/dev/null

  blk=$(jq -r '.block_subsystem // empty' <<<"$t")
  if [ -n "$blk" ]; then
    ensure views "name=${blk}" \
      "$(jq -c --argjson tid "$tid" --argjson pid "$pid" --arg n "$blk" \
        '{name:$n, path:("/"+$n), policy_id:$pid, tenant_id:$tid, protocols:["BLOCK"], create_dir:true}' <<<"$t")" "block-view" >/dev/null
  fi
done
log "tenant setup complete (idempotent)."
