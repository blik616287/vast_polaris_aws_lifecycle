#!/usr/bin/env bash
# =============================================================================
# preflight-reap.sh — one-shot: disconnect orphan NVMe/TCP controllers on EVERY
# node of a cluster, so block verification starts from a clean node.
#
# Runs a temporary privileged DaemonSet (one pod per node) that does a single
# immediate reap pass, prints what it cleared, then is deleted. Idempotent.
#
#   usage:  preflight-reap.sh <kubeconfig>
#
# Note: on a cluster running the nvme-tcp-orphan-reaper DaemonSet this is
# redundant (that keeps nodes clean continuously) — use it for clusters without
# it, or as a belt-and-suspenders step right before a demo/benchmark.
# =============================================================================
set -uo pipefail
KC="${1:?usage: preflight-reap.sh <kubeconfig>}"
K="kubectl --kubeconfig=$KC"

$K apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: vast-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/audit: privileged
---
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: nvme-reap-once, namespace: vast-system, labels: { app: nvme-reap-once } }
spec:
  selector: { matchLabels: { app: nvme-reap-once } }
  template:
    metadata: { labels: { app: nvme-reap-once } }
    spec:
      priorityClassName: system-node-critical
      tolerations: [ { operator: Exists } ]
      containers:
        - name: reap
          image: public.ecr.aws/docker/library/busybox:1.36
          securityContext: { privileged: true }
          command: ["/bin/sh", "-c"]
          args:
            - |
              R=0
              for c in /host/sys/class/nvme/nvme*; do
                [ -e "$c/transport" ] || continue
                n=$(basename "$c")
                [ "$(cat "$c/transport" 2>/dev/null)" = tcp ] || continue
                ls -d "$c/${n}n"* >/dev/null 2>&1 && continue
                echo "reaping orphan $n on $(hostname) (state=$(cat "$c/state" 2>/dev/null))"
                ( timeout 15 sh -c "echo 1 > $c/delete_controller" ) 2>/dev/null &
                R=$((R+1))
              done
              wait
              echo "REAPED=$R on $(hostname)"
              sleep 3600
          volumeMounts: [ { name: sys, mountPath: /host/sys } ]
      volumes: [ { name: sys, hostPath: { path: /sys } } ]
YAML

echo "preflight: reaping orphan NVMe/TCP controllers on all nodes…"
$K -n vast-system rollout status ds/nvme-reap-once --timeout=90s >/dev/null 2>&1 || true
sleep 3
$K -n vast-system logs -l app=nvme-reap-once --tail=30 2>/dev/null | grep -E 'reaping|REAPED' | sed 's/^/  /' \
  || echo "  (no reaper logs yet)"
$K -n vast-system delete ds/nvme-reap-once --wait=false >/dev/null 2>&1 || true
echo "preflight reap done."
