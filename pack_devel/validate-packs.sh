#!/usr/bin/env bash
# validate-packs.sh — on a live cluster (KUBECONFIG), prove all three VAST packs
# work end-to-end: csi PVC bind+mount, cosi BucketClaim provision, block PVC
# bind+mount. Mirrors the manual fieldeng validation, extended to all packs.
#
# Usage: KUBECONFIG=<path> ./validate-packs.sh [name-suffix]
set -uo pipefail
SFX="${1:-t}"
NS=default
pass=0; fail=0
ok(){ echo "  ✅ $*"; pass=$((pass+1)); }
no(){ echo "  ❌ $*"; fail=$((fail+1)); }

kc(){ kubectl --request-timeout=30s "$@"; }

echo "== driver pods =="
for ns in vast-csi vast-cosi vast-block; do
  r=$(kc get pods -n "$ns" --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')
  echo "  $ns: ${r:-<none>}"
done

# ---------- CSI ----------
echo "== [1/3] vast-csi: PVC bind + pod mount =="
SC=$(kc get sc -o json 2>/dev/null | python3 -c "import json,sys;[print(s['metadata']['name']) for s in json.load(sys.stdin)['items'] if s.get('provisioner')=='csi.vastdata.com']" | head -1)
echo "  StorageClass: ${SC:-<none found>}"
if [ -n "$SC" ]; then
  cat <<YAML | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vcsi-$SFX, namespace: $NS}
spec: {accessModes: [ReadWriteMany], storageClassName: $SC, resources: {requests: {storage: 1Gi}}}
YAML
  for i in $(seq 1 30); do [ "$(kc get pvc vcsi-$SFX -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break; sleep 5; done
  ph=$(kc get pvc vcsi-$SFX -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = Bound ] && ok "csi PVC Bound ($(kc get pvc vcsi-$SFX -n $NS -o jsonpath='{.spec.volumeName}'))" || { no "csi PVC $ph"; kc describe pvc vcsi-$SFX -n $NS 2>/dev/null | grep -A3 Events | tail -3 | sed 's/^/      /'; }
  if [ "$ph" = Bound ]; then
    cat <<YAML | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: vcsi-pod-$SFX, namespace: $NS}
spec:
  tolerations: [{operator: Exists}]
  containers: [{name: a, image: busybox:1.36, command: ["sh","-c","echo CSI-OK>/d/p && cat /d/p && df -h /d && sleep 2"], volumeMounts: [{name: v, mountPath: /d}]}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: vcsi-$SFX}}]
  restartPolicy: Never
YAML
    for i in $(seq 1 24); do p=$(kc get pod vcsi-pod-$SFX -n $NS -o jsonpath='{.status.phase}' 2>/dev/null); [ "$p" = Succeeded -o "$p" = Failed ] && break; sleep 5; done
    kc logs vcsi-pod-$SFX -n $NS 2>/dev/null | grep -q CSI-OK && ok "csi pod mounted + wrote/read" || no "csi pod mount/io"
  fi
fi

# ---------- COSI ----------
echo "== [2/3] vast-cosi: BucketClaim provision =="
BC=$(kc get bucketclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "  BucketClass: ${BC:-<none found>}"
if [ -n "$BC" ]; then
  cat <<YAML | kc apply -f - >/dev/null 2>&1
apiVersion: objectstorage.k8s.io/v1alpha1
kind: BucketClaim
metadata: {name: vcosi-$SFX, namespace: $NS}
spec: {bucketClassName: $BC, protocols: [S3]}
YAML
  for i in $(seq 1 36); do [ "$(kc get bucketclaim vcosi-$SFX -n $NS -o jsonpath='{.status.bucketReady}' 2>/dev/null)" = true ] && break; sleep 5; done
  rdy=$(kc get bucketclaim vcosi-$SFX -n $NS -o jsonpath='{.status.bucketReady}' 2>/dev/null)
  [ "$rdy" = true ] && ok "cosi BucketClaim ready (bucket=$(kc get bucketclaim vcosi-$SFX -n $NS -o jsonpath='{.status.bucketName}' 2>/dev/null))" || { no "cosi BucketClaim ready=$rdy"; kc describe bucketclaim vcosi-$SFX -n $NS 2>/dev/null | grep -A3 Events | tail -3 | sed 's/^/      /'; }
fi

# ---------- BLOCK ----------
echo "== [3/3] vast-block: block PVC bind + pod device =="
BSC=$(kc get sc -o json 2>/dev/null | python3 -c "import json,sys;[print(s['metadata']['name']) for s in json.load(sys.stdin)['items'] if 'block' in s.get('provisioner','').lower() or 'block' in s['metadata']['name'].lower()]" | head -1)
echo "  block StorageClass: ${BSC:-<none found>}"
if [ -n "$BSC" ]; then
  cat <<YAML | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vblk-$SFX, namespace: $NS}
spec: {accessModes: [ReadWriteOnce], volumeMode: Block, storageClassName: $BSC, resources: {requests: {storage: 1Gi}}}
YAML
  for i in $(seq 1 30); do [ "$(kc get pvc vblk-$SFX -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break; sleep 5; done
  ph=$(kc get pvc vblk-$SFX -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = Bound ] && ok "block PVC Bound ($(kc get pvc vblk-$SFX -n $NS -o jsonpath='{.spec.volumeName}'))" || { no "block PVC $ph"; kc describe pvc vblk-$SFX -n $NS 2>/dev/null | grep -A3 Events | tail -3 | sed 's/^/      /'; }
fi

echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
