#!/usr/bin/env bash
# CONTROL EXPERIMENT: the same Kubernetes upgrade of one region, WITHOUT draining it first,
# the way it is done when nobody has a pattern for it: change the version in Git and let
# Argo CD and System Upgrade Controller roll the nodes while the region keeps its place
# in DNS. Run `make watch` next to it and count the errors, then compare with `make
# demo-kubernetes` (same upgrade, the region drained first).
#   scripts/k8s-nodrain.sh <eu|us|cz> <version>      e.g. v1.36.6-k3s1
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
region=${1:?region (eu|us|cz)}; version=${2:?k3s version, e.g. v1.36.6-k3s1 (see: make freight)}
ctx=$(region_ctx "$region")

USER=gitea_admin; PASS=$(cat .secrets/gitea-admin-password)
PORT=${GITEA_LOCAL_PORT:-13000}
kubectl --context $MGMT -n gitea port-forward svc/gitea-http "$PORT:3000" >/dev/null 2>&1 &
PF=$!
work=$(mktemp -d)
trap 'kill $PF 2>/dev/null || true; rm -rf "${work:?}"' EXIT
for _ in $(seq 1 30); do curl -fsS "http://localhost:$PORT/api/healthz" >/dev/null 2>&1 && break; sleep 1; done

git clone -q "http://$USER:$PASS@localhost:$PORT/demo/gitops.git" "$work/repo"
cd "$work/repo"
git config user.name "an-engineer"; git config user.email "engineer@example.invalid"
for plan in plan-server plan-agent; do
  yq -i ".spec.version = \"$version\"" "platform/k8s/overlays/$region/$plan.yaml"
done
git commit -qam "kubernetes $version in $region (no drain)"
git push -q origin main
echo "pushed at $(date +%T): $region -> $version, region left in DNS rotation"
cd - >/dev/null

# Wait until the region's nodes are at the version (asked of its API server).
want=${version/-/+}
for _ in $(seq 1 120); do
  vs=$(kubectl --context "$ctx" --request-timeout=4s get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')
  [ "$vs" = "$want " ] && { echo "nodes of $region at $want at $(date +%T)"; exit 0; }
  sleep 5
done
echo "timeout waiting for the nodes of $region" >&2; exit 1
