# Shared by the scripts (source it, do not run it).
#
# REGIONS: region name : k3d cluster. Three regions; the order is the default rollout order.
# k8gb's geo tags are eu, us and cz (k8gb/Makefile CLUSTER_GEO_TAGS).
MGMT=k3d-mgmt
REGIONS=("eu:test-gslb1" "us:test-gslb2" "cz:test-gslb3")
REGION_NAMES=(eu us cz)

region_ctx() {   # <region> -> kube context of its cluster
  local e; for e in "${REGIONS[@]}"; do [ "${e%%:*}" = "$1" ] && { echo "k3d-${e##*:}"; return; }; done
  echo "unknown region '$1' (eu|us|cz)" >&2; return 1
}

# freight_name <name | k3s tag | empty> <project>
# Kargo names a Freight by a hash. People think in versions: accept a tag (v1.36.6-k3s1) too.
# With nothing given, the newest Freight overall is taken only if there is a single candidate.
freight_name() {
  local arg=${1:-} project=${2:-kubernetes} out
  case $arg in
    v1.*)
      out=$(kubectl --context $MGMT -n "$project" get freight -o json |
        jq -r --arg t "$arg" '[.items[] | select(.images[0].tag == $t)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty') ;;
    "") echo "give a Freight name or a k3s version (see: make freight)" >&2; return 1 ;;
    *)  out=$(kubectl --context $MGMT -n "$project" get freight -o json |
        jq -r --arg n "$arg" '[.items[] | select(.metadata.name | startswith($n))] | first | .metadata.name // empty') ;;
  esac
  [ -n "$out" ] || { echo "no Freight matches '$arg' in project $project (see: make freight)" >&2; return 1; }
  echo "$out"
}
