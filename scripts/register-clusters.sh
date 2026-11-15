#!/usr/bin/env bash
# Register the regional clusters in Argo CD (running in k3d-mgmt) and publish
# the region addresses the verifications need.
#
# kubeconfigs point at 127.0.0.1:<random port>, which does not exist from inside
# the mgmt cluster. Everything here uses names/IPs on the shared docker network
# (k3d-action-bridge-network) instead.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=k3d-action-bridge-network
# region:k3d-cluster
. scripts/lib.sh   # REGIONS (eu, us, cz)

container_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }

for entry in "${REGIONS[@]}"; do
  region=${entry%%:*}; cluster=${entry##*:}
  ctx=k3d-$cluster
  server="https://k3d-$cluster-serverlb:6443"
  kc=$(kubectl config view --raw --minify --context "$ctx" -o json)
  ca=$(jq -r '.clusters[0].cluster["certificate-authority-data"]' <<<"$kc")
  crt=$(jq -r '.users[0].user["client-certificate-data"]' <<<"$kc")
  key=$(jq -r '.users[0].user["client-key-data"]' <<<"$kc")
  cfg=$(jq -nc --arg ca "$ca" --arg crt "$crt" --arg key "$key" \
    '{tlsClientConfig:{caData:$ca,certData:$crt,keyData:$key}}')
  kubectl --context $MGMT -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$region
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    demo: k8gb-region-upgrades
type: Opaque
stringData:
  name: $region
  server: $server
  config: '$cfg'
EOF
  echo "registered $region -> $server"
done

# A READ-ONLY credential per region for the verification Jobs: "are the nodes at the version
# we asked for?" must be answered by the nodes, not by what Argo CD happens to show. It can
# only list nodes. The token goes to .secrets/ (never Git) and kargo-apply.sh puts it in a Secret.
: > .secrets/verifier.env; chmod 600 .secrets/verifier.env
for entry in "${REGIONS[@]}"; do
  region=${entry%%:*}; cluster=${entry##*:}; ctx=k3d-$cluster; up=$(echo "$region" | tr a-z A-Z)
  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: demo-verifier, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: demo-verifier}
rules:
  - {apiGroups: [""], resources: [nodes], verbs: [get, list]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: demo-verifier}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: demo-verifier}
subjects:
  - {kind: ServiceAccount, name: demo-verifier, namespace: kube-system}
EOF
  kc=$(kubectl config view --raw --minify --context "$ctx" -o json)
  {
    echo "${up}_API=https://k3d-$cluster-serverlb:6443"
    echo "${up}_CA=$(jq -r '.clusters[0].cluster["certificate-authority-data"]' <<<"$kc")"
    echo "${up}_TOKEN=$(kubectl --context "$ctx" -n kube-system create token demo-verifier --duration=8760h)"
  } >> .secrets/verifier.env
done
echo "read-only verifier credentials written to .secrets/verifier.env"

# Addresses used by the verification Jobs and watch.sh.
# k3d's servicelb publishes the nodes' docker-network IPs, and those are the
# addresses k8gb puts in DNS answers.
{
  echo "EDGEDNS_IP=$(container_ip k3d-edgedns-server-0)"
  echo "EDGEDNS_PORT=30053"
  for entry in "${REGIONS[@]}"; do
    region=${entry%%:*}; cluster=${entry##*:}
    ips="$(container_ip "k3d-$cluster-server-0") $(container_ip "k3d-$cluster-agent-0")"
    echo "$(echo "$region" | tr a-z A-Z)_IPS=$ips"
  done
  echo "GATEWAY_PORT=8000"
  echo "HOSTNAME=podinfo.cloud.example.com"
} > .secrets/regions.env
cat .secrets/regions.env
