#!/usr/bin/env bash
# The heart of the demo: one line per second showing what a client sees.
#
#   08:35:20  dns=[eu,cz] answer=eu  k8s=eu:v1.36.6,us:v1.35.9,cz:v1.36.6  err=0 <- dns: [cz,eu,us] -> [cz,eu]
#   08:35:52  dns=[eu,cz] answer=cz  k8s=eu:v1.36.6,us:v1.36.6,cz:v1.36.6  err=0 <- k8s: ... us:v1.35.9 -> us:v1.36.6
#
# Each tick: resolve the demo host through the edge DNS, call the first address
# returned, read podinfo's JSON. `err` counts failed requests; during a good
# rollout it stays where it is.
#
# The docker-network IPs k8gb returns are not routable from a Mac, so the probe
# runs inside a container on k3d-action-bridge-network (tools/probe.sh).
#
# Env: DURATION=<seconds> stop after N seconds; LOG_CSV=<file> also write CSV;
#      WATCH_CONTAINER=<name> container used for the probes (default demo-watch).
set -uo pipefail
cd "$(dirname "$0")/.."

. scripts/lib.sh   # REGIONS
NET=k3d-action-bridge-network
NAME=${WATCH_CONTAINER:-demo-watch}
DURATION=${DURATION:-0}
LOG_CSV=${LOG_CSV:-}

[ -s .secrets/regions.env ] || { echo "run scripts/register-clusters.sh first" >&2; exit 1; }
while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < .secrets/regions.env

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --rm --name "$NAME" --network "$NET" \
    -e EDGEDNS_IP -e EDGEDNS_PORT -e HOSTNAME -e GATEWAY_PORT \
    demo-tools:local sleep infinity >/dev/null
fi

kfile=$(mktemp)
cleanup() { kill "${POLLER:-0}" 2>/dev/null || true; rm -f "$kfile"; docker rm -f "$NAME" >/dev/null 2>&1 || true; summary; }
total=0; errors=0
summary() { echo; echo "requests=$total errors=$errors"; }
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

# Kubernetes version per region, polled in the background (kubectl is slow-ish).
# While a region's API server restarts (a Kubernetes upgrade) the read fails: keep the last value.
(
  last_eu="?"; last_us="?"; last_cz="?"
  while :; do
    kout=""
    for r in "${REGIONS[@]}"; do
      reg=${r%%:*}; ctx="k3d-${r#*:}"
      kv=$(kubectl --context "$ctx" --request-timeout=3s get node "${ctx}-server-0" \
        -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)
      if [ -n "$kv" ]; then eval "last_$reg=\${kv%%+*}"; fi
      eval "cur=\$last_$reg"
      kout="$kout${kout:+,}$reg:$cur"
    done
    echo "$kout" > "$kfile"; sleep 3
  done
) &
POLLER=$!

region_of_ip() {
  case " $EU_IPS " in *" $1 "*) echo eu; return;; esac
  case " $US_IPS " in *" $1 "*) echo us; return;; esac
  case " $CZ_IPS " in *" $1 "*) echo cz; return;; esac
  echo "?"
}

[ -n "$LOG_CSV" ] && echo "time,dns,answer,k8s,app,http,ms" > "$LOG_CSV"
prev_dns=""; prev_k8s=""; prev_app=""; app_eu="?"; app_us="?"; app_cz="?"; start=$(date +%s)
while :; do
  tick=$(date +%s)
  IFS='|' read -r ips code ver msg ms < <(docker exec "$NAME" probe.sh 2>/dev/null || echo "|000|||0")
  regions=""
  if [ -n "$ips" ]; then
    regions=$(for ip in ${ips//,/ }; do region_of_ip "$ip"; done | sort -u | paste -sd, -)
  fi
  dns="[${regions}]"
  k8s=$(cat "$kfile" 2>/dev/null); k8s=${k8s:-?}
  total=$((total + 1))
  [ "$code" = 200 ] || errors=$((errors + 1))
  # podinfo version per region, from whichever region answered (bash 3.2 on macOS: no assoc arrays)
  if [ "$code" = 200 ]; then
    case "$msg" in eu) app_eu=$ver ;; us) app_us=$ver ;; cz) app_cz=$ver ;; esac
  fi
  app="eu:$app_eu,us:$app_us,cz:$app_cz"

  note=""
  [ -n "$prev_dns" ] && [ "$dns" != "$prev_dns" ] && note="$note <- dns: $prev_dns -> $dns"
  [ -n "$prev_k8s" ] && [ "$k8s" != "$prev_k8s" ] && note="$note <- k8s: $prev_k8s -> $k8s"
  [ -n "$prev_app" ] && [ "$app" != "$prev_app" ] && note="$note <- app: $prev_app -> $app"
  [ "$code" = 200 ] || note="$note <- ERROR http=$code"
  prev_dns=$dns; prev_k8s=$k8s; prev_app=$app

  printf '%s  dns=%-7s answer=%-3s k8s=%s  err=%d%s\n' \
    "$(date +%T)" "$dns" "${msg:--}" "$k8s" "$errors" "$note"
  [ -n "$LOG_CSV" ] && echo "$(date +%T),\"$dns\",${msg:--},\"$k8s\",\"$app\",$code,$ms" >> "$LOG_CSV"

  [ "$DURATION" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$DURATION" ] && break
  elapsed=$(( $(date +%s) - tick )); [ "$elapsed" -lt 1 ] && sleep 0.7
done
