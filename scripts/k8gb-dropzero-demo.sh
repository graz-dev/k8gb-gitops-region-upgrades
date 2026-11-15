#!/usr/bin/env bash
# Try the upstream proposal live (upstream/k8gb-wrr-drop-zero-weights.md): with a CoreDNS
# built from upstream/coredns-crd-plugin/0001-wrr-optional-dropzero.patch and
# `loadbalance weight dropzero`, a region with weight 0 really leaves the DNS answers, so a
# drain is a plain weight change (no `failover` trick) and works for any number of regions.
#
#   scripts/k8gb-dropzero-demo.sh build     build the patched CoreDNS image (needs Go + Docker)
#   scripts/k8gb-dropzero-demo.sh install   load it into both regions and enable dropzero
#   scripts/k8gb-dropzero-demo.sh drain     weight eu=0 through Git, show the DNS answers
#   scripts/k8gb-dropzero-demo.sh restore   back to the normal rotation
#   scripts/k8gb-dropzero-demo.sh uninstall back to the upstream CoreDNS image
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN_DIR=${PLUGIN_DIR:-}            # a checkout of k8gb-io/coredns-crd-plugin (build only)
IMG=k8s_crd; TAG=dropzero
EU=k3d-test-gslb1; US=k3d-test-gslb2
H=podinfo.cloud.example.com

answers() { # label port
  printf '  %-12s' "$1"
  for i in 1 2 3 4 5 6; do dig @127.0.0.1 -p "$2" $H +tcp +short | tr '\n' ' '; echo; done | sort | uniq -c | sed 's/^ *//' | paste -sd'|' -
}
show() { answers "eu coredns" 5053; answers "us coredns" 5054; answers "edge (BIND)" 1053; }

edit_rotation() { # yq expression applied to gslb/rotation.yaml in the Gitea repo, then wait for Argo CD
  local expr=$1 pass port=13002 work pf
  pass=$(cat .secrets/gitea-admin-password)
  kubectl --context k3d-mgmt -n gitea port-forward svc/gitea-http "$port:3000" >/dev/null 2>&1 & pf=$!
  work=$(mktemp -d); trap 'kill $pf 2>/dev/null || true; rm -rf "${work:?}"' RETURN
  for _ in $(seq 1 30); do curl -fsS "http://localhost:$port/api/healthz" >/dev/null 2>&1 && break; sleep 1; done
  git clone -q "http://gitea_admin:$pass@localhost:$port/demo/gitops.git" "$work/r"
  (cd "$work/r" && git config user.name demo && git config user.email demo@example.invalid &&
    yq -i "$expr" gslb/rotation.yaml && git commit -qam "dropzero demo: $expr" && git push -q origin main)
  ./scripts/sync.sh gslb-eu gslb-us >/dev/null
}

case ${1:?build|install|drain|restore|uninstall} in
  build)
    [ -d "${PLUGIN_DIR:?set PLUGIN_DIR to a checkout of k8gb-io/coredns-crd-plugin}" ] || exit 1
    (cd "$PLUGIN_DIR" && git apply --check "$OLDPWD/upstream/coredns-crd-plugin/0001-wrr-optional-dropzero.patch" 2>/dev/null &&
      git apply "$OLDPWD/upstream/coredns-crd-plugin/0001-wrr-optional-dropzero.patch" || true
      GOOS=linux GOARCH="$(docker info --format '{{.Architecture}}' | sed 's/x86_64/amd64/;s/aarch64/arm64/')" CGO_ENABLED=0 \
        go build -o coredns cmd/coredns.go && docker build -q -t "$IMG:$TAG" .) ;;
  install)
    # The Corefile lives in k8gb's ConfigMap (CoreDNS reloads it by itself every 30 s), the
    # image in the Deployment. Both are changed in place for the experiment; `helm upgrade`
    # would put them back, and `uninstall` does it explicitly.
    for c in test-gslb1 test-gslb2; do k3d image import "$IMG:$TAG" -c "$c" >/dev/null; done
    for ctx in $EU $US; do
      kubectl --context $ctx -n k8gb get cm k8gb-coredns -o json |
        jq '.data.Corefile |= (if test("weight dropzero") then . else sub("loadbalance weight"; "loadbalance weight dropzero") end)' |
        kubectl --context $ctx apply -f - >/dev/null
      kubectl --context $ctx -n k8gb set image deploy/k8gb-coredns "*=$IMG:$TAG" >/dev/null
      kubectl --context $ctx -n k8gb rollout status deploy/k8gb-coredns --timeout=180s >/dev/null
      echo "$ctx: $(kubectl --context $ctx -n k8gb get deploy k8gb-coredns -o jsonpath='{.spec.template.spec.containers[0].image}')"
    done ;;
  drain)
    echo "== before"; show
    edit_rotation '.spec.strategy.type = "roundRobin" | del(.spec.strategy.primaryGeoTag) | .spec.strategy.weight = {"eu": 0, "us": 1}'
    sleep 15; echo "== eu weight 0, us weight 1 (roundRobin, no failover)"; show ;;
  restore)
    edit_rotation '.spec.strategy.type = "roundRobin" | .spec.strategy.primaryGeoTag = "us" | del(.spec.strategy.weight)'
    sleep 15; echo "== back to normal"; show ;;
  uninstall)
    for ctx in $EU $US; do
      kubectl --context $ctx -n k8gb get cm k8gb-coredns -o json |
        jq '.data.Corefile |= sub("loadbalance weight dropzero"; "loadbalance weight")' | kubectl --context $ctx apply -f - >/dev/null
      kubectl --context $ctx -n k8gb set image deploy/k8gb-coredns "*=registry.k8gb.io/k8gb-io/k8s_crd:v0.7.0" >/dev/null
      kubectl --context $ctx -n k8gb rollout status deploy/k8gb-coredns --timeout=180s >/dev/null
    done ;;
esac
