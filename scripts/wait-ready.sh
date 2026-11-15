#!/usr/bin/env bash
# Block until the demo is really ready: every Argo CD Application Synced and Healthy, and the
# EDGE DNS answers with the addresses of ALL THREE regions for 10 consecutive queries. Right after
# `make up` the DNS can still be converging (k8gb publishes through external-dns), and a
# rollout started then would be measured against a system that is not serving yet.
set -euo pipefail
TIMEOUT=${TIMEOUT:-600}
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  bad=$(kubectl --context k3d-mgmt -n argocd get applications -o json |
    jq -r '[.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy")] | length')
  ok=0
  if [ "$bad" = 0 ]; then
    for _ in $(seq 1 10); do
      n=$(dig @127.0.0.1 -p 1053 podinfo.cloud.example.com +tcp +time=2 +tries=1 +short 2>/dev/null | grep -cE '^[0-9.]+$' || true)
      [ "$n" -ge 6 ] && ok=$((ok + 1)) || break
      sleep 1
    done
  fi
  [ "$ok" = 10 ] && { echo "ready: applications healthy, edge DNS answers for all three regions"; exit 0; }
  sleep 5
done
echo "not ready after ${TIMEOUT}s: $bad application(s) not healthy, edge DNS returned $n address(es)" >&2
exit 1
