#!/usr/bin/env bash
# Trigger a sync of Argo CD Applications and wait for each to be Synced and Healthy.
# Used for the very first sync and by `make reset`; afterwards Argo CD syncs by itself.
# A failed sync (typically a transient network error while Argo CD renders a remote
# chart) is retried up to 3 times.
#   scripts/sync.sh k8s-eu k8s-us ...
set -euo pipefail
MGMT=k3d-mgmt
TIMEOUT=${TIMEOUT:-420}
ATTEMPTS=${ATTEMPTS:-3}
PATCH='{"operation":{"initiatedBy":{"username":"scripts/sync.sh"},"sync":{"syncOptions":["ServerSideApply=true","CreateNamespace=true"]}}}'

request_sync() {
  local app=$1
  kubectl --context $MGMT -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  # another operation may be running (automated sync): wait a moment and try again
  kubectl --context $MGMT -n argocd patch application "$app" --type merge -p "$PATCH" >/dev/null 2>&1 ||
    { sleep 3; kubectl --context $MGMT -n argocd patch application "$app" --type merge -p "$PATCH" >/dev/null 2>&1 || true; }
}

for app in "$@"; do request_sync "$app"; done

deadline=$(( $(date +%s) + TIMEOUT ))
for app in "$@"; do
  attempt=1
  while :; do
    json=$(kubectl --context $MGMT -n argocd get application "$app" -o json)
    phase=$(jq -r '.status.operationState.phase // "none"' <<<"$json")
    sync=$(jq -r '.status.sync.status' <<<"$json")
    health=$(jq -r '.status.health.status' <<<"$json")
    case "$phase" in
      Succeeded)
        if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then echo "$app: Succeeded sync=$sync health=$health"; break; fi ;;
      Failed|Error)
        echo "$app: attempt $attempt $phase: $(jq -r '.status.operationState.message' <<<"$json")" >&2
        [ "$attempt" -lt "$ATTEMPTS" ] || exit 1
        attempt=$((attempt + 1)); sleep 10; request_sync "$app" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || { echo "$app: timeout (phase=$phase sync=$sync health=$health)" >&2; exit 1; }
    sleep 3
  done
done
