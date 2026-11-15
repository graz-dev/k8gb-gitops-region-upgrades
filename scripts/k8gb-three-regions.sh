#!/usr/bin/env bash
# k8gb only, no GitOps: what do the ways of taking a region out of DNS do with THREE regions?
# Run it after `make base-up` and BEFORE `make bootstrap`/`wire`: it deploys podinfo and a Gslb
# straight into the three clusters (Argo CD would revert manual changes), measures, and cleans up.
#
# For each mode it prints, for the edge DNS (what resolvers see) and for each region's own CoreDNS:
#   the region of the FIRST address returned, over 12 queries (what most clients use), and
#   the regions present in one full answer.
#
#   scripts/k8gb-three-regions.sh              run every mode below
#   scripts/k8gb-three-regions.sh <mode>...    run only these modes
#
# modes:
#   roundrobin       baseline: all three regions in rotation
#   failover-us      `failover`, primaryGeoTag=us: what the demo uses to drain (2 regions); with 3?
#   failover-eu-down `failover`, primaryGeoTag=eu AND eu's workload unhealthy (the "split to all the
#                    others" behaviour a maintainer described): who gets eu's traffic?
#   weight0          roundRobin, weights eu=0 us=1 cz=1 on the STOCK CoreDNS: is eu out?
#   dropzero         the same weights with the patched CoreDNS (`loadbalance weight dropzero`,
#                    tools/coredns-dropzero/); needs `scripts/k8gb-dropzero-demo.sh build` once
#   dropzero-uneven  weights eu=0 us=3 cz=1: the others share in proportion (40 queries)
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=(k3d-test-gslb1 k3d-test-gslb2 k3d-test-gslb3)
REGION=(eu us cz)
H=podinfo.cloud.example.com
IMG=k8s_crd:dropzero
MODES=("$@"); [ ${#MODES[@]} -gt 0 ] || MODES=(roundrobin failover-us failover-eu-down weight0 dropzero dropzero-uneven)

declare -a EP   # EP[i] = the docker-network addresses of region i's nodes (what k8gb publishes)
for i in 0 1 2; do
  c=${CTX[$i]#k3d-}
  EP[$i]="$(docker inspect -f '{{(index .NetworkSettings.Networks "k3d-action-bridge-network").IPAddress}}' "k3d-$c-server-0") $(docker inspect -f '{{(index .NetworkSettings.Networks "k3d-action-bridge-network").IPAddress}}' "k3d-$c-agent-0")"
done
region_of() { for i in 0 1 2; do case " ${EP[$i]} " in *" $1 "*) echo "${REGION[$i]}"; return;; esac; done; echo "?"; }

apply_all() { for i in 0 1 2; do kubectl --context "${CTX[$i]}" apply -k "gitops/apps/podinfo/overlays/${REGION[$i]}" >/dev/null; kubectl --context "${CTX[$i]}" apply -k gitops/gslb >/dev/null; done; }
cleanup() {
  for i in 0 1 2; do
    kubectl --context "${CTX[$i]}" delete -k gitops/gslb --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl --context "${CTX[$i]}" delete -k "gitops/apps/podinfo/overlays/${REGION[$i]}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    uninstall_dropzero "${CTX[$i]}"
  done
}
install_dropzero() { # ctx
  local ctx=$1 n=${1##k3d-}
  grep -q "weight dropzero" < <(kubectl --context "$ctx" -n k8gb get cm k8gb-coredns -o jsonpath='{.data.Corefile}') && return 0
  k3d image import "$IMG" -c "$n" >/dev/null
  kubectl --context "$ctx" -n k8gb get cm k8gb-coredns -o json | jq '.data.Corefile |= sub("loadbalance weight"; "loadbalance weight dropzero")' | kubectl --context "$ctx" replace -f - >/dev/null
  kubectl --context "$ctx" -n k8gb set image deploy/k8gb-coredns "*=$IMG" >/dev/null
  kubectl --context "$ctx" -n k8gb rollout status deploy/k8gb-coredns --timeout=180s >/dev/null
}
uninstall_dropzero() { # ctx
  local ctx=$1
  grep -q "weight dropzero" < <(kubectl --context "$ctx" -n k8gb get cm k8gb-coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) || return 0
  kubectl --context "$ctx" -n k8gb get cm k8gb-coredns -o json | jq '.data.Corefile |= sub("loadbalance weight dropzero"; "loadbalance weight")' | kubectl --context "$ctx" replace -f - >/dev/null
  kubectl --context "$ctx" -n k8gb set image deploy/k8gb-coredns "*=registry.k8gb.io/k8gb-io/k8s_crd:v0.7.0" >/dev/null
  kubectl --context "$ctx" -n k8gb rollout status deploy/k8gb-coredns --timeout=180s >/dev/null
}
set_strategy() { # json for spec.strategy (merge patch; null removes a key)
  for c in "${CTX[@]}"; do
    kubectl --context "$c" -n podinfo patch gslbs.k8gb.io podinfo --type merge -p "{\"spec\":{\"strategy\":$1}}" >/dev/null
  done
}
count() { # port samples -> "N region" lines of the FIRST address
  for _ in $(seq 1 "$2"); do dig @127.0.0.1 -p "$1" $H +tcp +short +time=3 | head -1 | tr -dc '0-9.\n'; done |
    while read -r ip; do [ -n "$ip" ] && region_of "$ip"; done | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}'
}
fullanswer() { dig @127.0.0.1 -p "$1" $H +tcp +short +time=3 | tr -dc '0-9.\n' | while read -r ip; do [ -n "$ip" ] && region_of "$ip"; done | sort -u | paste -sd, -; }
measure() { # samples
  local n=${1:-12} name port
  for t in edge:1053 eu:5053 us:5054 cz:5055; do
    name=${t%%:*}; port=${t##*:}
    printf '  %-5s coredns/edge  first address -> %-28s full answer has: %s\n' "$name" "$(count "$port" "$n")" "[$(fullanswer "$port")]"
  done
}
settle() { sleep "${1:-30}"; }

trap 'echo; echo "cleaning up"; cleanup' EXIT
echo "deploying podinfo + Gslb directly in the three regions (no Argo CD)"
apply_all
for c in "${CTX[@]}"; do kubectl --context "$c" -n podinfo rollout status deploy/podinfo --timeout=180s >/dev/null; done
settle 40

for m in "${MODES[@]}"; do
  echo; echo "== $m"
  case $m in
    roundrobin)       set_strategy '{"type":"roundRobin","weight":null}'; settle; measure ;;
    failover-us)      set_strategy '{"type":"failover","primaryGeoTag":"us","weight":null}'; settle; measure ;;
    failover-eu-down) set_strategy '{"type":"failover","primaryGeoTag":"eu","weight":null}'
                      kubectl --context "${CTX[0]}" -n podinfo scale deploy podinfo --replicas=0 >/dev/null
                      settle 40; measure
                      echo "  (eu's Gslb health: $(kubectl --context "${CTX[0]}" -n podinfo get gslbs.k8gb.io podinfo -o jsonpath='{.status.serviceHealth}'))"
                      kubectl --context "${CTX[0]}" -n podinfo scale deploy podinfo --replicas=2 >/dev/null
                      kubectl --context "${CTX[0]}" -n podinfo rollout status deploy/podinfo --timeout=120s >/dev/null ;;
    weight0)          set_strategy '{"type":"roundRobin","primaryGeoTag":"us","weight":{"eu":0,"us":1,"cz":1}}'; settle; measure ;;
    dropzero|dropzero-uneven)
                      docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  skipped: build the patched CoreDNS first (scripts/k8gb-dropzero-demo.sh build)"; continue; }
                      for c in "${CTX[@]}"; do install_dropzero "$c"; done; settle 30
                      if [ "$m" = dropzero ]; then
                        set_strategy '{"type":"roundRobin","primaryGeoTag":"us","weight":{"eu":0,"us":1,"cz":1}}'; settle; measure
                      else
                        set_strategy '{"type":"roundRobin","primaryGeoTag":"us","weight":{"eu":0,"us":3,"cz":1}}'; settle; measure 40
                      fi ;;
    *) echo "unknown mode $m" >&2; exit 2 ;;
  esac
done
