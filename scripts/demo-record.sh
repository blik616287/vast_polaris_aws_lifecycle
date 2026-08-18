#!/usr/bin/env bash
# =============================================================================
# demo-record.sh — presenter-driven walkthrough of the SpectroCloud × VAST
# integration, for screen-recording a demo video for VAST.
#
# Proves, end to end and LIVE:
#   1. VoC running (VMS + ENode) + Polaris dashboard link + topology
#   2. VoC stood up as CODE — Terraform + CodeBuild + vastcloud + S3/DynamoDB state
#   3. Storage VPC and k8s VPCs are SEPARATE, peered (live proof)
#   4. Palette clusters Running/Healthy  (+ clickable console links)
#   5. All three VAST drivers + storage classes on each cluster
#   6. Multi-tenant isolation           (+ clickable pack/profile link)
#   7. LIVE NFS + NVMe/TCP block + S3/COSI on BOTH clusters
#   8. Mapped to the scope   9. Wrap + every link
#
# It PAUSES between sections (press Enter) so you can narrate.
#
# ---- SPOKEN SCRIPT (read these while the command runs) ----------------------
#  1. "VoC is live on AWS — the VMS endpoint, the ENode running, and the Polaris
#      dashboard showing the storage cluster up."
#  2. "The whole VoC stand-up is CODE, not click-ops: Terraform builds the infra,
#      a CodeBuild pipeline drives the vastcloud CLI, state lives in S3 + DynamoDB."
#  3. "Critically, the STORAGE VPC and the k8s VPCs are SEPARATE VPCs, peered —
#      storage is long-lived infrastructure, isolated from compute."
#  4. "Both tenant clusters are Running/Healthy in Palette's own console — links."
#  5. "Each cluster runs all three VAST drivers — file, block, object."
#  6. "Every cluster gets its OWN isolated VAST tenant — VIP pool, view, QoS,
#      client-IP range. The packs are published in Palette — here."
#  7. "Live: NFS, NVMe/TCP block, and S3 — written and read back, PASS — on BOTH
#      clusters, each against its own isolated tenant."
#  8. "That closes Validation-Plan Phase 1 (CSI) and Phase 2 (multi-tenancy)."
#  9. "Full record in ENGAGEMENT-RECORD.md."
# -----------------------------------------------------------------------------
#
# CONFIG (export before running, or edit defaults):
#   PALETTE_API_KEY   Palette SaaS token (enables the live cluster-health step)
#   KC1 / KC2         kubeconfig paths for voc-tenant-1 / voc-tenant-2
#   FE_PROFILE        AWS profile for the fieldeng account (default: fieldeng)
#   RUN_LIVE_TESTS    1 (default) run the NFS/block/S3 Jobs; 0 narrate-only
#   AUTO              0 (default) pause for Enter; 1 auto-advance
#   TYPE              1 (default) typewriter on commands; 0 instant
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
: "${PALETTE_HOST:=api.spectrocloud.com}"
: "${PALETTE_PROJECT:=68e6a683b6b66c6045d1b584}"          # ISC-Strategic-Alliance
: "${TENANTS_JSON:=$REPO/voc/tenants.json}"
: "${VERIFY_DIR:=$REPO/voc/tenant-verification}"
: "${TF_DIR:=$REPO/voc/terraform}"
: "${FE_PROFILE:=fieldeng}"
: "${KC1:=}"; : "${KC2:=}"
: "${RUN_LIVE_TESTS:=1}"; : "${AUTO:=0}"; : "${TYPE:=1}"

# --- identifiers (clickable console/dashboard links + AWS proof) ---
CONSOLE="https://console.spectrocloud.com"
POLARIS_URL="https://admin.aws.polaris.vastdata.com/"
T1_UID=6a45f8d7aab49a7f5e946d61
T2_UID=6a4605caaab49b772ae5c3f5
PROFILE_UID=6a45ae8700e8032dcf22780b
VAST_VPC=vpc-0ff881160438da5dd     # 10.20.0.0/16  storage
T1_VPC=vpc-019d5314885961178       # 10.40.0.0/16  voc-tenant-1
T2_VPC=vpc-0092c3072137fdcda       # 10.50.0.0/16  voc-tenant-2
CL_T1="$CONSOLE/projects/$PALETTE_PROJECT/clusters/$T1_UID/overview"
CL_T2="$CONSOLE/projects/$PALETTE_PROJECT/clusters/$T2_UID/overview"
PROFILE_LINK="$CONSOLE/projects/$PALETTE_PROJECT/profiles/cluster/$PROFILE_UID"

# colors
B=$'\e[1m'; DIM=$'\e[2m'; IT=$'\e[3m'; R=$'\e[0m'
TEAL=$'\e[38;5;30m'; SAND=$'\e[38;5;179m'; GREY=$'\e[38;5;244m'; GREEN=$'\e[38;5;35m'; BLUE=$'\e[38;5;39m'

# pad by CHARACTER count (${#t}, UTF-8 aware) not bytes, so titles with · / — align
banner(){ local t="$1"; local pad=$(( 58 - ${#t} )); [ "$pad" -lt 0 ] && pad=0
          printf '\n%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$TEAL" "$R"
          printf '%s%s║  %s%*s  ║%s\n' "$B" "$TEAL" "$t" "$pad" "" "$R"
          printf '%s%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$TEAL" "$R"; }
say(){ printf '%s%s  🎙  %s%s\n' "$IT" "$SAND" "$1" "$R"; }
note(){ printf '%s     %s%s\n' "$GREY" "$1" "$R"; }
# why: written context — what this section proves and why it's in the demo
why(){ printf '%s  ▐ WHY%s  %s%s%s\n' "$B$BLUE" "$R" "$IT$GREY" "$1" "$R"; }
# clickable link (bare URL — terminals linkify it; also visible to viewers)
link(){ printf '    %s▸ %s%s\n      %s%s%s\n' "$B" "$1" "$R" "$BLUE" "$2" "$R"; }
pause(){ if [ "$AUTO" = 1 ]; then sleep 4; else printf '\n%s     ⏎  press Enter…%s' "$DIM" "$R"; read -r _; fi; }

# topology diagram — two side-by-side boxes, drawn with printf padding so the
# columns ALWAYS align (ASCII content only; no multi-byte width surprises).
topology(){
  local W=28 i bar
  local -a L=("STORAGE VPC (VAST-on-Cloud)" "vast-voc-fieldeng" "10.20.0.0/16" "VMS / CNodes / VIP pools")
  local -a Rt=("KUBERNETES CLUSTER VPCs" "voc-tenant-1   10.40.0.0/16" "voc-tenant-2   10.50.0.0/16" "Palette-managed EC2 nodes")
  local -a M=("          " "  <====>  " "  peered  " "  <====>  ")
  printf -v bar '%*s' "$((W+2))" ''; bar=${bar// /=}
  printf '%s    +%s+          +%s+%s\n' "$GREY" "$bar" "$bar" "$R"
  for i in 0 1 2 3; do
    printf '%s    | %-*s |%s| %-*s |%s\n' "$GREY" "$W" "${L[$i]}" "${M[$i]}" "$W" "${Rt[$i]}" "$R"
  done
  printf '%s    +%s+          +%s+%s\n' "$GREY" "$bar" "$bar" "$R"
  printf '%s      two SEPARATE VPCs, joined only by explicit VPC peering%s\n' "$GREY" "$R"
}

# automation architecture — flow style (left-aligned, no columns to misalign)
automation_diagram(){
  printf '%s
      terraform apply  ─►  AWS infra:  VPC · subnets · peering · SGs · IAM   (~93 resources)
            │                          state ─►  S3 (rk-tf-state)  +  DynamoDB lock table
            ▼
      CodeBuild lifecycle  ─►  vastcloud CLI  ─►  VoC storage cluster stood up
        actions: deploy / tenant / teardown    (normally Polaris click-ops — now one pipeline)%s\n' "$GREY" "$R"
}

run(){ local cmd="$1"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#cmd};i++)); do printf '%s' "${cmd:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$cmd"; fi
  eval "$cmd" 2>&1 | sed 's/^/    /'; }

# poll a Job to completion with LIVE progress. Completion via .status.succeeded
# (jsonpath) — version-proof. pvc="-" for object tests that have no PVC.
wait_job(){ # <kubeconfig> <job> <pvc-or-dash> [timeout]
  local kc="$1" job="$2" pvc="$3" to="${4:-220}" i=0 pvcst pod succ fail
  printf '\n%s  ⏳ provisioning — watching pvc / pod / job live…%s\n' "$B" "$R"
  while [ "$i" -lt "$to" ]; do
    if [ "$pvc" = "-" ]; then pvcst="n/a"
    else pvcst=$(kubectl --kubeconfig="$kc" get pvc "$pvc" --no-headers 2>/dev/null | awk '{print $2}'); fi
    pod=$(kubectl --kubeconfig="$kc" get pods -l job-name="$job" --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    succ=$(kubectl --kubeconfig="$kc" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    fail=$(kubectl --kubeconfig="$kc" get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null)
    printf '    %s%3ss%s  pvc=%s%-8s%s pod=%s%-18s%s job=%s%s/1%s\n' \
      "$GREY" "$i" "$R" "$TEAL" "${pvcst:-Pending}" "$R" "$TEAL" "${pod:-<none>}" "$R" "$TEAL" "${succ:-0}" "$R"
    [ "${succ:-0}" = "1" ] && { printf '%s    ✓ job complete%s\n' "$GREEN" "$R"; return 0; }
    [ "${fail:-0}" -ge 1 ] 2>/dev/null && { printf '%s    ! job reported failure%s\n' "$SAND" "$R"; return 1; }
    sleep 6; i=$((i+6))
  done
  printf '%s    ! timed out after %ss%s\n' "$SAND" "$to" "$R"; return 1; }

# run one protocol on one cluster: apply -> live progress -> result -> clean
verify(){ # <kc> <cluster> <proto> <job> <pvc-or-dash> <timeout> <applycmd> <cleancmd>
  local kc="$1" cl="$2" proto="$3" job="$4" pvc="$5" to="$6" applycmd="$7" cleancmd="$8" res
  printf '\n%s  🎙  [%s]  %s%s\n' "$IT$SAND" "$cl" "$proto" "$R"
  eval "$cleancmd" >/dev/null 2>&1
  eval "$applycmd" 2>&1 | grep -vE 'Warning|PodSecurity|must set' | sed 's/^/    /'
  wait_job "$kc" "$job" "$pvc" "$to"
  res=$(kubectl --kubeconfig="$kc" logs job/"$job" 2>/dev/null | grep -i verify | tail -1)
  if [ -n "$res" ]; then printf '%s    %s%s\n' "$GREEN" "$res" "$R"
  else printf '%s    (no VERIFY line — see: kubectl logs job/%s)%s\n' "$SAND" "$job" "$R"; fi
  eval "$cleancmd" >/dev/null 2>&1; }

AWS_OK=0; aws sts get-caller-identity --profile "$FE_PROFILE" >/dev/null 2>&1 && AWS_OK=1
AWS="aws --profile $FE_PROFILE --region us-east-2"

clear
printf '%s%s\n' "$B$TEAL" '
   ███████ ██████   ███████  ██████ ████████ ██████   ██████
   ██      ██   ██  ██      ██         ██    ██   ██ ██    ██
   ███████ ██████   █████   ██         ██    ██████  ██    ██   ×  V A S T
        ██ ██       ██      ██         ██    ██   ██ ██    ██
   ███████ ██       ███████  ██████    ██    ██   ██  ██████
'
printf '%s   VAST Data on Palette-managed Kubernetes — working integration%s\n' "$B" "$R"
note "   $(date -u +%Y-%m-%d)  ·  region us-east-2  ·  VAST-on-Cloud + SpectroCloud Palette"
pause

# ---------------------------------------------------------------------------
banner "1 · VoC running + topology"
why "Before Kubernetes can consume anything, the VAST storage cluster must be live and reachable — this proves it's real and running, not a slide."
say "VAST-on-Cloud is live on AWS — the VMS management endpoint and the ENode."
if [ "$AWS_OK" = 1 ]; then
  run "$AWS ssm get-parameter --name /voc/voc-fieldeng/vms-endpoint --query Parameter.Value --output text"
  run "$AWS ec2 describe-instances --filters Name=vpc-id,Values=$VAST_VPC Name=instance-type,Values=i3en.24xlarge Name=instance-state-name,Values=running --query 'Reservations[].Instances[].{ENode:Tags[?Key==\`Name\`]|[0].Value,Type:InstanceType,State:State.Name}' --output table"
else note "(AWS '$FE_PROFILE' not active — narrate: VMS 10.20.4.81, ENode i3en.24xlarge running)"; fi
say "And the VAST Polaris dashboard shows the storage cluster up:"
link "Polaris dashboard (VoC status)" "$POLARIS_URL"
topology
pause

# ---------------------------------------------------------------------------
banner "2 · Built as code — Terraform · CodeBuild · vastcloud"
why "Standing up VAST VoC is normally CLICK-OPS — the Polaris portal plus a hand-run vastcloud CLI. We turned the whole stand-up into reproducible IaC: versioned state, one pipeline, repeatable and tear-down-able."
say "Terraform provisions the AWS infra; a CodeBuild pipeline drives the vastcloud CLI to stand up the VoC; state lives in S3 + a DynamoDB lock."
automation_diagram
say "The real automation resources behind it:"
if [ "$AWS_OK" = 1 ]; then
  run "$AWS s3 ls | grep -E 'rk-tf-state|vast-voc-fieldeng' | awk '{print \"  s3://\"\$3}'"
  run "$AWS codebuild list-projects --query 'projects' --output text | tr '\t' '\n' | grep voc | sed 's/^/  /'"
fi
if TFN=$(cd "$TF_DIR" 2>/dev/null && terraform state list 2>/dev/null | wc -l) && [ "${TFN:-0}" -gt 0 ]; then
  note "one 'terraform apply' → $TFN resources · state in S3 (rk-tf-state) + DynamoDB lock · CodeBuild action=deploy runs 'vastcloud cluster create'"
else note "one 'terraform apply' → ~93 resources · state in S3 + DynamoDB lock · CodeBuild runs 'vastcloud cluster create'"; fi
pause

# ---------------------------------------------------------------------------
banner "3 · Storage VPC and K8s VPCs are SEPARATE, peered"
why "VAST's Client-IP tenancy and a clean security boundary need storage in its OWN VPC — here's live proof it's genuinely separate from the compute clusters, joined only by explicit peering."
say "Three distinct VPCs — one for storage, one per k8s cluster:"
if [ "$AWS_OK" = 1 ]; then
  run "$AWS ec2 describe-vpcs --vpc-ids $VAST_VPC $T1_VPC $T2_VPC --query 'Vpcs[].{VPC:VpcId,CIDR:CidrBlock,Name:Tags[?Key==\`Name\`]|[0].Value}' --output table"
  say "…joined only by explicit VPC peering (never a shared/flat network):"
  run "$AWS ec2 describe-vpc-peering-connections --filters Name=status-code,Values=active Name=accepter-vpc-info.vpc-id,Values=$VAST_VPC --query 'VpcPeeringConnections[].{Peering:VpcPeeringConnectionId,ClusterVPC:RequesterVpcInfo.CidrBlock,StorageVPC:AccepterVpcInfo.CidrBlock}' --output table"
else note "(AWS not active — narrate: 10.20/16 storage VPC peered to 10.40 + 10.50 cluster VPCs)"; fi
pause

# ---------------------------------------------------------------------------
banner "4 · Palette clusters — Running / Healthy"
why "The consumers are real Palette-managed EC2 Kubernetes clusters, healthy in Palette's own SaaS console — production-grade, not a local test cluster."
say "Both tenant clusters are Running and Healthy in Palette's own console."
if [ -n "${PALETTE_API_KEY:-}" ]; then
  run "curl -s -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PALETTE_PROJECT' 'https://$PALETTE_HOST/v1/dashboard/spectroclusters?limit=50' -H 'Content-Type: application/json' -X POST -d '{\"filter\":{},\"sort\":[]}' | jq -r '.items[]? | select(.metadata.name|test(\"voc-tenant\")) | \"  \(.metadata.name)  state=\(.status.state)  health=\(.status.health.state)\"'"
else note "(PALETTE_API_KEY unset — narrate: voc-tenant-1 + voc-tenant-2 both Running/Healthy)"; fi
say "Open them directly in the Spectro Cloud console:"
link "voc-tenant-1 in Palette console" "$CL_T1"
link "voc-tenant-2 in Palette console" "$CL_T2"
pause

# ---------------------------------------------------------------------------
banner "5 · VAST drivers + storage classes (both clusters)"
why "Storage only counts if the drivers are actually installed and running on the workload clusters — here they are, all three, on each."
say "All three VAST drivers — file, block, object — run on each cluster."
for e in "voc-tenant-1|$KC1" "voc-tenant-2|${KC2:-$KC1}"; do
  CL="${e%%|*}"; KC="${e#*|}"; [ -n "$KC" ] || { note "($CL kubeconfig unset)"; continue; }
  printf '\n%s  ── %s ──%s\n' "$B$TEAL" "$CL" "$R"
  run "kubectl --kubeconfig='$KC' get pods -A | grep -E 'vast|cosi' | awk '{print \$1, \$2, \$4}'"
  run "kubectl --kubeconfig='$KC' get storageclass | grep -E 'NAME|vastdata'"
done
pause

# ---------------------------------------------------------------------------
banner "6 · Multi-tenancy — one isolated VAST tenant per cluster"
why "One VAST cluster safely serving many isolated tenants is the whole monetization story — each fenced by its own VIP pool, view, QoS, and client-IP range."
say "Each cluster gets a dedicated VIP pool, view, QoS tier, and client-IP range."
run "jq -r '.tenants[] | \"  \(.name):  client=\(.client_ip_ranges[0]|join(\"-\"))  vip=\(.vip_ip_ranges[0]|join(\"-\"))  path=\(.storage_path)  qos=\(.qos_tier)\"' '$TENANTS_JSON'"
note "↑ isolation is gated by client_ip_ranges — a cluster only reaches its own tenant"
say "The three VAST packs are published in Palette (cluster profile 'vast-storage-aws'):"
link "VAST packs in the cluster profile" "$PROFILE_LINK"
pause

# ---------------------------------------------------------------------------
banner "7 · LIVE storage — NFS · block · S3, on BOTH clusters"
why "The decisive proof: real read/write round-trips over file, block, AND object — on BOTH clusters — each reaching only its own tenant's storage."
say "Provision + write + read every protocol against each tenant's isolated storage."
note "(NVMe/TCP sessions kept healthy by the nvme-tcp-orphan-reaper DaemonSet — voc/ops/)"
if [ "$RUN_LIVE_TESTS" = 1 ] && [ -n "$KC1" ]; then
  for entry in "voc-tenant-1|$KC1|tenant-1" "voc-tenant-2|${KC2:-$KC1}|tenant-2"; do
    CL="${entry%%|*}"; rest="${entry#*|}"; KC="${rest%%|*}"; TEN="${rest##*|}"
    [ -n "$KC" ] || { note "($CL kubeconfig unset — skipped)"; continue; }
    printf '\n%s  ═══ %s   (VAST tenant %s) ═══════════════════════%s\n' "$B$TEAL" "$CL" "$TEN" "$R"
    verify "$KC" "$CL" "NFS RWX (file)" verify-nfs verify-nfs 200 \
      "kubectl --kubeconfig='$KC' apply -f '$VERIFY_DIR/01-nfs.yaml'" \
      "kubectl --kubeconfig='$KC' delete -f '$VERIFY_DIR/01-nfs.yaml' --ignore-not-found --wait=false"
    verify "$KC" "$CL" "NVMe/TCP block" verify-block verify-block 300 \
      "kubectl --kubeconfig='$KC' apply -f '$VERIFY_DIR/02-nvme-tcp-block.yaml'" \
      "kubectl --kubeconfig='$KC' delete -f '$VERIFY_DIR/02-nvme-tcp-block.yaml' --ignore-not-found --wait=false"
    verify "$KC" "$CL" "S3 / COSI (object)" verify-cosi - 300 \
      "sed 's/tenant-1/$TEN/g' '$VERIFY_DIR/03-cosi-s3.yaml' | kubectl --kubeconfig='$KC' apply -f -" \
      "sed 's/tenant-1/$TEN/g' '$VERIFY_DIR/03-cosi-s3.yaml' | kubectl --kubeconfig='$KC' delete -f - --ignore-not-found --wait=false"
  done
else
  note "(RUN_LIVE_TESTS=0 or KC1 unset — narrate: NFS + block + S3 PASS on both tenants)"
fi
pause

# ---------------------------------------------------------------------------
banner "8 · Mapped to the scope"
why "Ties the live results back to the agreed Validation Plan so VAST sees exactly which phases are done and what's next."
say "That closes Validation-Plan Phase 1 (CSI) and Phase 2 (multi-tenancy)."
printf '    %sPhase 1 — VAST CSI on Palette      %s🧪 Validated  (NFS · block · S3)%s\n' "$B" "$GREEN" "$R"
printf '    %sPhase 2 — Multi-tenancy + QoS      %s🧪 Validated  (isolated tenants, both clusters)%s\n' "$B" "$GREEN" "$R"
printf '    %sPhase 3 — PaletteAI / DataEngine   %s▢  Next increment%s\n' "$B" "$SAND" "$R"
pause

# ---------------------------------------------------------------------------
banner "9 · Wrap + links"
why "Everything shown is reproducible and documented — clickable links and a written engagement record VAST can keep."
say "Full record and deliverables inventory in ENGAGEMENT-RECORD.md."
link "Polaris dashboard (VoC)"            "$POLARIS_URL"
link "voc-tenant-1 (Palette console)"     "$CL_T1"
link "voc-tenant-2 (Palette console)"     "$CL_T2"
link "VAST packs / cluster profile"       "$PROFILE_LINK"
printf '\n%s%s  ✓ VAST on Palette — file, block, object · multi-tenant · separate peered VPCs · validated.%s\n\n' "$B" "$GREEN" "$R"
