#!/usr/bin/env bash
# Manual drain/restore, the way a human would do it without Kargo (milestone M1):
# edit gitops/gslb/rotation.yaml in the Git repo, push, let Argo CD apply it.
#   scripts/rotation.sh drain eu [receiver]   # eu out of DNS rotation (failover, primary = the receiver:
#                                             # us by default, the region that serves everybody meanwhile)
#   scripts/rotation.sh restore eu            # all regions in rotation (roundRobin)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
action=${1:?drain|restore}; region=${2:?region (eu|us|cz)}
region_ctx "$region" >/dev/null
case $region in eu) receiver=us ;; us) receiver=cz ;; cz) receiver=eu ;; esac   # same ring as the pipeline
receiver=${3:-$receiver}
[ "$receiver" != "$region" ] || { echo "the receiver must be another region" >&2; exit 2; }

USER=gitea_admin; PASS=$(cat .secrets/gitea-admin-password)
PORT=${GITEA_LOCAL_PORT:-13000}
kubectl --context $MGMT -n gitea port-forward svc/gitea-http "$PORT:3000" >/dev/null 2>&1 &
PF=$!
work=$(mktemp -d)
trap 'kill $PF 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 1 30); do curl -fsS "http://localhost:$PORT/api/healthz" >/dev/null 2>&1 && break; sleep 1; done

git clone -q "http://$USER:$PASS@localhost:$PORT/demo/gitops.git" "$work/repo"
cd "$work/repo"
git config user.name "manual"; git config user.email "manual@example.invalid"
case $action in
  drain)   yq -i ".spec.strategy.type = \"failover\" | .spec.strategy.primaryGeoTag = \"$receiver\" | .metadata.annotations.\"region-upgrades-drained\" = \"$region\"" gslb/rotation.yaml ;;
  restore) yq -i '.spec.strategy.type = "roundRobin" | .metadata.annotations."region-upgrades-drained" = ""' gslb/rotation.yaml ;;
  *) echo "action must be drain or restore" >&2; exit 2 ;;
esac
git diff --stat
git commit -qam "manual: $action $region"
git push -q origin main
cd - >/dev/null

date +%T | sed 's/^/pushed at /'
./scripts/sync.sh gslb-eu gslb-us gslb-cz
date +%T | sed 's/^/applied at /'
