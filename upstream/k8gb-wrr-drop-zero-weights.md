# k8gb / coredns-crd-plugin: let `weight: 0` really take a region out of the answer

*Draft issue + PR description. Not filed.*

## Problem

`docs/strategy.md` says weighted round robin can set a region to 0% "so that the last region is
practically disabled". In practice a region with weight 0 is **still in every DNS answer**, just
last. Through a parent DNS that reorders answers (BIND does) it is the *first* address a client sees
a third to a half of the time, and any client that tries more than one address, or the last one,
reaches it. This makes `weight: 0` unusable for the planned-maintenance case ("drain this region,
change it, put it back"), which is the main reason to want a weight of 0.

## Evidence

Two clusters (eu, us), `Gslb` with `strategy.type: roundRobin`, `weight: {eu: 0, us: 1}`. The
`DNSEndpoint` carries `weight-eu-0-0: 172.18.0.6` and `weight-us-0-1: 172.18.0.11`, so the weight
reaches CoreDNS. Querying eu's CoreDNS 12 times:

```
11x  172.18.0.11 172.18.0.12 172.18.0.6 172.18.0.7      # us, us, EU, EU
 1x  172.18.0.12 172.18.0.11 172.18.0.6 172.18.0.7
```

Through the edge BIND (12 queries) EU's addresses came first in 6 of them. Raw output:
`evidence/three-regions-spike/modes.txt`, `NOTES.md` section 1.

Cause: `service/wrr/wrr.go` calls `ws.PickVector(gows.IncludeZeroWeights)`, hard-coded. The
`go-weight-shuffling` library already has the other mode, `DropZeroWeights`
("a weight of 0 turns the index off"), with the example `[0,50,50,0,0,0] -> [1,2]`.

## Proposed change

Make it a Corefile option, default unchanged (no behaviour change for anyone):

```
k8s_crd cloud.example.com {
    loadbalance weight dropzero
}
```

* `wrr.NewWeightRoundRobin(opts ...Option)` with `wrr.DropZeroWeights()`.
* If every weight is 0 nothing is dropped, so a misconfiguration never produces an empty answer.
* Chart: a value such as `coredns.dropZeroWeights` that renders `loadbalance weight dropzero`.

Patch (5 files, +202/-4, new test file with the Apache license header; an unknown `loadbalance` option is ignored with a warning, so a Corefile written for a newer build still loads) with four weighting tests (default keeps zero weights last; dropzero leaves the
region out, repeated 50 times because the order is random; all-zero keeps everything; positive
regions only): `coredns-crd-plugin/0001-wrr-optional-dropzero.patch`. The existing tests pass.

## Measured with three regions (`evidence/three-regions-spike/modes.txt`)

`failover` with a healthy primary returns ONLY the primary from every cluster, so draining one of three regions also takes the third out (the
primary serves everybody). `failover` with the drained region as primary and its workload unhealthy splits its traffic over the others, but
the region cannot then be verified while drained. `roundRobin` with `weight: 0` keeps the region in every answer (edge BIND first 4/12);
with `loadbalance weight dropzero` it leaves, and the others share by weight (24/16 of 40 for 3:1).

## Effect

With this a drain is a one-line weight change and works for **any number of regions**. Today the
demo has to use the `failover` strategy pinned to the other region, which works for two regions only.
Tried live in the demo with a CoreDNS image built from the patch: see `NOTES.md`, "weight with dropzero".

## Open questions for maintainers

* Option name (`dropzero`?) and whether the default should eventually change.
* Should the operator/`Gslb` expose it per resource instead of per CoreDNS?
