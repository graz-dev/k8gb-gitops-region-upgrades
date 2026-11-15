#!/usr/bin/env bash
# Create the mgmt cluster and install cert-manager, Argo CD, Gitea, Argo Rollouts (for Kargo
# verification) and Kargo. Idempotent and retrying.
# Requires the k8gb clusters (make base-up) because mgmt joins their docker network.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source bootstrap/versions.env

CTX=k3d-mgmt
TRIES=${TRIES:-5}
mkdir -p .secrets && chmod 700 .secrets

retry() {
  local n=1
  until "$@"; do
    if [ "$n" -ge "$TRIES" ]; then echo "giving up after $n attempts: $*" >&2; return 1; fi
    echo "attempt $n failed, retrying in 15s: $*" >&2
    n=$((n + 1)); sleep 15
  done
}

docker network inspect k3d-action-bridge-network >/dev/null 2>&1 ||
  { echo "k3d-action-bridge-network missing: run 'make base-up' first" >&2; exit 1; }

# --- secrets (generated once, gitignored) -----------------------------------
gen() { [ -s ".secrets/$1" ] || { openssl rand -base64 18 | tr -d '/+=\n' | cut -c1-20 > ".secrets/$1"; }; }
gen kargo-admin-password
gen gitea-admin-password
[ -s .secrets/kargo-signing-key ] || openssl rand -base64 29 | tr -d '=+/\n' > .secrets/kargo-signing-key
[ -s .secrets/kargo-admin-hash ] ||
  htpasswd -bnBC 10 "" "$(cat .secrets/kargo-admin-password)" | tr -d ':\n' | sed 's/$2y/$2a/' > .secrets/kargo-admin-hash

# --- cluster -----------------------------------------------------------------
if ! k3d cluster list mgmt >/dev/null 2>&1; then
  retry k3d cluster create -c k3d/mgmt.yaml
fi
# right after creation the node object may not be registered yet
until kubectl --context $CTX get nodes --no-headers 2>/dev/null | grep -q .; do sleep 2; done
kubectl --context $CTX wait --for=condition=Ready node --all --timeout=180s

# --- helm repos (only the ones we need: an unrelated broken repo must not fail us)
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add gitea-charts https://dl.gitea.com/charts/ --force-update >/dev/null
retry helm repo update jetstack argo gitea-charts >/dev/null

H="helm --kube-context $CTX"

echo "== cert-manager $CERT_MANAGER_VERSION"
retry $H upgrade -i cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait --timeout 5m

# A self-signed issuer is all Kargo's webhooks and API cert need.
kubectl --context $CTX apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF

echo "== Argo CD $ARGOCD_CHART_VERSION"
retry $H upgrade -i argocd argo/argo-cd -n argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" -f bootstrap/argocd-values.yaml --wait --timeout 8m

echo "== Gitea $GITEA_CHART_VERSION"
retry $H upgrade -i gitea gitea-charts/gitea -n gitea --create-namespace \
  --version "$GITEA_CHART_VERSION" -f bootstrap/gitea-values.yaml \
  --set gitea.admin.username=gitea_admin \
  --set gitea.admin.password="$(cat .secrets/gitea-admin-password)" \
  --wait --timeout 8m

echo "== Argo Rollouts $ARGO_ROLLOUTS_VERSION (analysis CRDs + controller)"
# Kargo creates AnalysisRuns for verification but does not execute them: the Argo Rollouts
# controller does (it runs the Job metrics). No Rollout resources are used, only AnalysisRuns.
for crd in analysis-run-crd analysis-template-crd cluster-analysis-template-crd experiment-crd rollout-crd; do
  retry kubectl --context $CTX apply --server-side -f \
    "https://raw.githubusercontent.com/argoproj/argo-rollouts/$ARGO_ROLLOUTS_VERSION/manifests/crds/$crd.yaml"
done
retry $H upgrade -i argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace \
  --version "$ARGO_ROLLOUTS_CHART_VERSION" --set installCRDs=false --set dashboard.enabled=false --wait --timeout 5m

echo "== Kargo $KARGO_VERSION"
retry $H upgrade -i kargo oci://ghcr.io/akuity/kargo-charts/kargo -n kargo --create-namespace \
  --version "$KARGO_VERSION" -f bootstrap/kargo-values.yaml \
  --set api.adminAccount.passwordHash="$(cat .secrets/kargo-admin-hash)" \
  --set api.adminAccount.tokenSigningKey="$(cat .secrets/kargo-signing-key)" \
  --wait --timeout 8m

echo "bootstrap done"
