#!/usr/bin/env bash
# M5 (exploration): what does it take to upgrade k8gb region by region with the
# drain pattern? Each phase prints what it measured; paste the output into NOTES.md.
#
#   scripts/k8gb-experiment.sh setup     both regions on the N-1 chart (v1.0.0)
#   scripts/k8gb-experiment.sh happy     drain eu, upgrade k8gb in eu to N (v1.0.1), measure DNS
#   scripts/k8gb-experiment.sh skew      eu on N, us on N-1, both in rotation: anything break?
#   scripts/k8gb-experiment.sh broken    drained eu with a broken k8gb: how much leaks to clients?
#   scripts/k8gb-experiment.sh finish    us to N, everything restored
#
# Probes run in a container on the docker network (the IPs are not routable from
# the Mac) against: the edge BIND (what resolvers see), eu's CoreDNS and us's CoreDNS directly.
set -euo pipefail
cd "$(dirname "$0")/.."
OLD=v1.0.0; NEW=v1.0.1
EU=k3d-test-gslb1; US=k3d-test-gslb2
H="podinfo.cloud.example.com"
OUT=.logs/k8gb-exp; mkdir -p $OUT

while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < .secrets/regions.env
EU_NS=${EU_IPS%% *}; US_NS=${US_IPS%% *}

tools() {
  docker ps --format '{{.Names}}' | grep -qx demo-watch ||
    docker run -d --rm --name demo-watch --network k3d-action-bridge-network \
      -e EDGEDNS_IP -e EDGEDNS_PORT -e HOSTNAME -e GATEWAY_PORT demo-tools:local sleep infinity >/dev/null
}

# probe <label> <ip> <port> <seconds> : one query per 0.2 s, counts the DNS status of each answer
probe() {
  local label=$1 ip=$2 port=$3 secs=$4
  docker exec demo-watch sh -c "
    end=\$(( \$(date +%s) + $secs ))
    while [ \$(date +%s) -lt \$end ]; do
      r=\$(dig +tcp +time=1 +tries=1 @$ip -p $port $H A +noall +comments 2>&1 | grep -oE 'status: [A-Z]+' | head -1 | cut -d' ' -f2)
      if [ -z \"\$r\" ]; then r=TIMEOUT; elif [ \"\$r\" = NOERROR ]; then
        n=\$(dig +tcp +time=1 +tries=1 @$ip -p $port $H A +short | grep -cE '^[0-9.]+\$' || true); r=\"NOERROR(\$n records)\"; fi
      echo \"\$r\"; sleep 0.2
    done" | sort | uniq -c | sed "s/^/  [$label] /" > "$OUT/probe-$label.txt" &
}
probes() { # seconds
  probe edge "$EDGEDNS_IP" "$EDGEDNS_PORT" "$1"
  probe eu-coredns "$EU_NS" 53 "$1"
  probe us-coredns "$US_NS" 53 "$1"
}
show_probes() { wait; cat $OUT/probe-edge.txt $OUT/probe-eu-coredns.txt $OUT/probe-us-coredns.txt; }

# --reuse-values keeps k8gb.imageTag pinned by the original install (k8gb's Makefile
# sets it), so changing only --version would swap the chart templates but keep the
# OLD IMAGES running. Set the operator and CoreDNS images explicitly for each version
# (the CoreDNS image is the chart's default for that version).
helm_k8gb() { # ctx version
  helm repo update k8gb >/dev/null 2>&1 || true
  local coredns_tag
  coredns_tag=$(helm show values k8gb/k8gb --version "$2" | yq '.coredns.image.tag')
  local t0=$(date +%s)
  helm --kube-context "$1" -n k8gb upgrade k8gb k8gb/k8gb --version "$2" --reuse-values \
    --set k8gb.imageTag="$2" --set coredns.image.tag="$coredns_tag" --wait --timeout 6m >/dev/null
  echo "  helm upgrade $1 -> chart $2 (operator $2, coredns $coredns_tag) took $(( $(date +%s) - t0 ))s"
}
versions() {
  for c in $EU $US; do
    echo "  $c: chart=$(helm --kube-context $c -n k8gb list -o json | jq -r '.[]|select(.name=="k8gb").chart')" \
      "operator=$(kubectl --context $c -n k8gb get deploy k8gb -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's#.*/##')" \
      "coredns=$(kubectl --context $c -n k8gb get deploy k8gb-coredns -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's#.*/##')"
  done
}
dns_ips() { dig +tcp +short @127.0.0.1 -p 1053 $H A | sort | tr '\n' ' '; echo; }

phase=${1:?setup|happy|skew|broken|finish}
tools
case $phase in
  setup)
    helm repo add k8gb https://www.k8gb.io --force-update >/dev/null; helm repo update k8gb >/dev/null
    helm_k8gb $EU $OLD; helm_k8gb $US $OLD; versions ;;

  happy)
    echo "== happy path: drain eu, upgrade k8gb in eu $OLD -> $NEW"
    ./scripts/rotation.sh drain eu | grep -E 'applied'
    echo "  edge DNS while drained: $(dns_ips)"
    probes 100
    sleep 5
    helm_k8gb $EU $NEW
    sleep 20
    show_probes
    versions
    echo "  edge DNS after upgrade (eu still drained): $(dns_ips)"
    ./scripts/rotation.sh restore eu | grep -E 'applied'
    echo "  edge DNS after restore: $(dns_ips)" ;;

  skew)
    echo "== version skew: eu on $NEW, us on $OLD, both in rotation"
    versions
    probes 60
    show_probes
    for c in $EU $US; do
      echo "  $c Gslb: $(kubectl --context $c -n podinfo get gslbs.k8gb.io podinfo -o jsonpath='{.status.healthyRecords}')"
      echo "  $c operator errors (last 5 min): $(kubectl --context $c -n k8gb logs deploy/k8gb --since=5m 2>&1 | grep -ciE ' ERR |error' || true)"
    done ;;

  broken)
    echo "== failure path: eu drained, k8gb in eu broken. What leaks to clients?"
    ./scripts/rotation.sh drain eu | grep -E 'applied'
    echo "-- (a) the operator stops publishing: records are gone from eu's CoreDNS (NXDOMAIN)"
    kubectl --context $EU -n k8gb scale deploy/k8gb --replicas=0 >/dev/null
    kubectl --context $EU -n podinfo delete dnsendpoints.externaldns.k8s.io podinfo >/dev/null
    sleep 10; probes 40; show_probes
    kubectl --context $EU -n k8gb scale deploy/k8gb --replicas=1 >/dev/null
    kubectl --context $EU -n k8gb rollout status deploy/k8gb --timeout=120s >/dev/null
    echo "-- (b) eu's CoreDNS is down (crash loop / bad build): resolvers time out on that NS"
    kubectl --context $EU -n k8gb scale deploy/k8gb-coredns --replicas=0 >/dev/null
    sleep 5; probes 40; show_probes
    kubectl --context $EU -n k8gb scale deploy/k8gb-coredns --replicas=1 >/dev/null
    kubectl --context $EU -n k8gb rollout status deploy/k8gb-coredns --timeout=120s >/dev/null
    ./scripts/rotation.sh restore eu | grep -E 'applied' ;;

  finish)
    ./scripts/rotation.sh drain us | grep -E 'applied'
    helm_k8gb $US $NEW
    ./scripts/rotation.sh restore us | grep -E 'applied'
    versions; echo "  edge DNS: $(dns_ips)" ;;
esac
