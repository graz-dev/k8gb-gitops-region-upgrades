#!/usr/bin/env bash
# Re-learn the docker-network addresses of the clusters' containers.
#
# Why: Docker may give a container a DIFFERENT IP when it is restarted, and the Kubernetes
# upgrade restarts the node containers (k3s replaces its binary and the container restarts).
# Five things hold addresses and go stale:
#   0. each cluster's k3d load balancer and each k3s agent (they may dial another cluster's node);
#   1. the mgmt cluster's CoreDNS (k3d writes the container names -> IPs once, at creation):
#      Argo CD then cannot reach a region ("no route to host" to its old address);
#   2. .secrets/regions.env: the region addresses watch.sh and the verifications compare with;
#   3. the `regions` ConfigMap in the Kargo project (a copy of 2).
# Run it whenever something that worked starts failing with "no route to host", after an upgrade
# round, or let `make ready` do it. Idempotent and quick.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
NET=k3d-action-bridge-network

# 0. each cluster's load balancer (k3d-<cluster>-serverlb) resolves its server's address once, at start.
#    After addresses moved it may forward to ANOTHER cluster's node (kubectl then fails with an x509
#    error, or hangs). A node that does not answer to its own name means: restart its load balancer.
for e in "${REGIONS[@]}"; do
  cluster=${e##*:}
  if ! kubectl --context "k3d-$cluster" --request-timeout=8s get node "k3d-$cluster-server-0" >/dev/null 2>&1; then
    echo "k3d-$cluster: API unreachable or wrong cluster behind its load balancer, restarting it"
    docker restart "k3d-$cluster-serverlb" >/dev/null
    for _ in $(seq 1 20); do
      kubectl --context "k3d-$cluster" --request-timeout=8s get node "k3d-$cluster-server-0" >/dev/null 2>&1 && break; sleep 3
    done
  fi
done

# 0b. a k3s AGENT remembers its server's address (k3s-agent-load-balancer.json). If the server came back
#     with another address the agent keeps dialling the old one, which may now be another cluster's
#     server: the node goes NotReady with "x509: certificate signed by unknown authority". Forget it.
for e in "${REGIONS[@]}"; do
  cluster=${e##*:}
  sip=$(docker inspect -f '{{(index .NetworkSettings.Networks "k3d-action-bridge-network").IPAddress}}' "k3d-$cluster-server-0")
  f=/var/lib/rancher/k3s/agent/etc/k3s-agent-load-balancer.json
  cached=$(docker exec "k3d-$cluster-agent-0" cat $f 2>/dev/null | jq -r '.ServerAddresses[0] // ""' | cut -d: -f1)
  if [ -n "$cached" ] && [ "$cached" != "$sip" ]; then
    echo "k3d-$cluster-agent-0 still dials $cached, its server is $sip: resetting"
    docker exec "k3d-$cluster-agent-0" mv $f $f.stale
    docker restart "k3d-$cluster-agent-0" >/dev/null
    for _ in $(seq 1 30); do
      [ "$(kubectl --context "k3d-$cluster" --request-timeout=8s get node "k3d-$cluster-agent-0" --no-headers 2>/dev/null | awk '{print $2}')" = Ready ] && break; sleep 5
    done
  fi
done

hosts=$(docker network inspect "$NET" -f '{{range .Containers}}{{.IPv4Address}} {{.Name}}{{"\n"}}{{end}}' |
  sed 's#/[0-9]*##' | grep -E ' k3d-' | sort -k2)
hosts=$(printf '192.168.5.2 host.k3d.internal\n%s\n' "$hosts")

current=$(kubectl --context $MGMT -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}')
if [ "$(printf '%s\n' "$current" | sort)" != "$(printf '%s\n' "$hosts" | sort)" ]; then
  kubectl --context $MGMT -n kube-system patch cm coredns --type merge \
    -p "$(jq -nc --arg h "$hosts" '{data:{NodeHosts:$h}}')" >/dev/null
  echo "mgmt CoreDNS: container addresses updated (it reloads in about 15 s)"
  sleep 20
  kubectl --context $MGMT -n argocd rollout restart statefulset/argocd-application-controller >/dev/null 2>&1 ||
    kubectl --context $MGMT -n argocd rollout restart deploy/argocd-application-controller >/dev/null 2>&1 || true
else
  echo "mgmt CoreDNS: addresses already current"
fi

# 4. each REGION's own CoreDNS: when a node's address changes, k3s rewrites NodeHosts with the node
#    list only and drops `host.k3d.internal`, the name k8gb's external-dns uses to reach the edge
#    DNS. Without it the region can no longer publish its records ("lookup host.k3d.internal: no such host").
hostline=$(printf '%s\n' "$hosts" | grep ' host.k3d.internal$')
for e in "${REGIONS[@]}"; do
  ctx=k3d-${e##*:}
  nh=$(kubectl --context "$ctx" -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}')
  if ! grep -q ' host.k3d.internal$' <<<"$nh"; then
    kubectl --context "$ctx" -n kube-system patch cm coredns --type merge \
      -p "$(jq -nc --arg h "$(printf '%s\n%s\n' "$nh" "$hostline")" '{data:{NodeHosts:$h}}')" >/dev/null
    echo "$ctx: put host.k3d.internal back into CoreDNS"
  fi
done

./scripts/register-clusters.sh >/dev/null
if kubectl --context $MGMT get ns kubernetes >/dev/null 2>&1; then
  kubectl --context $MGMT -n kubernetes create configmap regions --from-env-file=.secrets/regions.env \
    --dry-run=client -o yaml | kubectl --context $MGMT -n kubernetes apply -f - >/dev/null
fi
echo "region addresses:"; grep _IPS .secrets/regions.env | sed 's/^/  /'
