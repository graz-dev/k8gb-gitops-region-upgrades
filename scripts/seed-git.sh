#!/usr/bin/env bash
# Create the demo Git repo in the in-cluster Gitea, push ./gitops to it as a
# fresh history, and give Argo CD credentials to read it.
#
# Gitea is the repo Argo CD reads and Kargo pushes to. Running it in-cluster
# keeps the demo self-contained (no GitHub account or token). Using GitHub
# instead is not wired up.
#
# Re-running RESETS the repo to the contents of ./gitops (force push). That is
# what `make reset` relies on.
set -euo pipefail
cd "$(dirname "$0")/.."

MGMT=k3d-mgmt
USER=gitea_admin
PASS=$(cat .secrets/gitea-admin-password)
PORT=${GITEA_LOCAL_PORT:-13000}   # 3000 is taken by test-gslb1
ORG=demo
REPO=gitops
IN_CLUSTER_URL="http://gitea-http.gitea.svc.cluster.local:3000/$ORG/$REPO.git"

kubectl --context $MGMT -n gitea rollout status deploy/gitea --timeout=180s >/dev/null
kubectl --context $MGMT -n gitea port-forward svc/gitea-http "$PORT:3000" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS "http://localhost:$PORT/api/healthz" >/dev/null 2>&1 && break; sleep 1; done

api() { curl -sS -u "$USER:$PASS" -H 'Content-Type: application/json' "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' -u "$USER:$PASS" "$@"; }

[ "$(code "http://localhost:$PORT/api/v1/orgs/$ORG")" = 200 ] ||
  api -X POST "http://localhost:$PORT/api/v1/orgs" -d "{\"username\":\"$ORG\"}" >/dev/null
[ "$(code "http://localhost:$PORT/api/v1/repos/$ORG/$REPO")" = 200 ] ||
  api -X POST "http://localhost:$PORT/api/v1/orgs/$ORG/repos" \
    -d "{\"name\":\"$REPO\",\"private\":true,\"default_branch\":\"main\"}" >/dev/null

work=$(mktemp -d)
trap 'kill $PF 2>/dev/null || true; rm -rf "$work"' EXIT
cp -R gitops/. "$work/"
# KEEP_VERSIONS=1 (make reset): keep the Kubernetes overlays that are in the repo now.
# Reseeding them would put the old version back and, with automated sync, Argo CD would try
# to DOWNGRADE Kubernetes, which it does not support.
if [ "${KEEP_VERSIONS:-0}" = 1 ] && git ls-remote --exit-code "http://$USER:$PASS@localhost:$PORT/$ORG/$REPO.git" main >/dev/null 2>&1; then
  git clone -q "http://$USER:$PASS@localhost:$PORT/$ORG/$REPO.git" "$work.current"
  for d in platform/k8s; do
    rm -rf "${work:?}/$d"; cp -R "$work.current/$d" "$work/$d"
  done
  rm -rf "${work:?}.current"
  echo "kept the current platform/k8s from the repo"
fi
(
  cd "$work"
  git init -q -b main
  git config user.name "demo-seed"; git config user.email "seed@example.invalid"
  git add -A
  git commit -q -m "Seed: desired state of the zero-traffic region upgrades demo"
  git push -q --force "http://$USER:$PASS@localhost:$PORT/$ORG/$REPO.git" main
)
echo "pushed ./gitops -> $IN_CLUSTER_URL (branch main)"

# Argo CD repository credentials
kubectl --context $MGMT -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: $IN_CLUSTER_URL
  username: $USER
  password: $PASS
EOF
echo "argo cd repo credentials ready"
