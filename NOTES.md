# NOTES: findings, gotchas, measured numbers, upstream ideas

Living log of what running the system showed; facts here come from runs, not from docs. 2026-11-13..15. k8gb at commit `901a4f2`
(chart `v1.0.1`), Argo CD `v3.6.1`, Kargo `v1.12.5`, System Upgrade Controller `v0.21.1`, k3s `v1.35.9` → `v1.36.6` → `v1.37.2`.
The first runs had two regions and an Istio pipeline (both removed); their raw output is not in this repository, only the files cited below.
Section numbers are referenced from code comments.

## 1. `weight: 0` does NOT take a region out of DNS rotation (changes the design)

The first plan for this demo assumed k8gb's weighted round robin with `weight: 0` removes a region
from DNS answers. **It does not.**

Experiment: Gslb with `strategy.type: roundRobin`, `weight: {eu: 0, us: 1}`,
applied to both clusters (confirmed with `kubectl get gslbs.k8gb.io`).

```
$ dig @127.0.0.1 -p 5053 podinfo.cloud.example.com +tcp +short      # eu's own CoreDNS, 12 queries
  11x  172.18.0.11 172.18.0.12 172.18.0.6 172.18.0.7      # us, us, EU, EU
   1x  172.18.0.12 172.18.0.11 172.18.0.6 172.18.0.7
$ dig @127.0.0.1 -p 1053 podinfo.cloud.example.com +tcp +short      # through the edge BIND, 12 queries
   4x  172.18.0.6 172.18.0.7 172.18.0.11 172.18.0.12      # EU first!
   4x  172.18.0.12 172.18.0.6 172.18.0.7 172.18.0.11
   2x  172.18.0.7 172.18.0.11 172.18.0.12 172.18.0.6
   2x  172.18.0.11 172.18.0.12 172.18.0.6 172.18.0.7
```

Cause (code, `k8gb-io/coredns-crd-plugin`, `service/wrr/wrr.go`):
`vector := ws.PickVector(gows.IncludeZeroWeights)`. The plugin returns **all**
records and only **orders** them by weight; zero-weight groups are appended at
the end. The `DNSEndpoint` does carry `weight-eu-0-0: 172.18.0.6`, so the weight
reaches CoreDNS, it just doesn't filter. This is the "order and frequency"
caveat in `docs/wrr_caveats.md`, one step further: with a parent DNS that
reorders answers (BIND does), a weight-0 region is first in the answer a third
to a half of the time. `docs/strategy.md` says weight 0 makes a region
"practically disabled"; that is true only for a client that takes the last record.

**What works instead: `failover` with `primaryGeoTag` set to the other region.**

```
Gslb strategy {type: failover, primaryGeoTag: us}      # eu drained
$ dig @127.0.0.1 -p 5053 ... +short   ->  172.18.0.11 172.18.0.12          # eu's CoreDNS
$ dig @127.0.0.1 -p 5054 ... +short   ->  172.18.0.11 172.18.0.12          # us's CoreDNS
$ dig @127.0.0.1 -p 1053 ... +short   ->  172.18.0.11 172.18.0.12          # edge, 20/20 queries
```

The drained region's addresses are really gone from every answer, while its
workload stays healthy and testable by direct IP. Failover keeps the drained
region as a last resort if the primary has no healthy pods, which is the
behaviour you want from a DR spare. Restore = back to `roundRobin`.

Gotcha found on the way: `weight` is only valid with `type: roundRobin`
(`controllers/resolver/spec_validations.go`). Setting `type: failover` while a
`weight` map is still present makes the operator log `strategy=roundRobin`
and ignore the change; remove `weight` when switching. We drop `weight` entirely.

Consequences:
- Single source of truth is `gitops/gslb/rotation.yaml` (a kustomize patch), not `weights.yaml`.
- Works for 2 regions. With 3 regions (measured in §10) failover has one primary, so draining one
  of three needs a different mechanism. **Upstream idea:** a real "exclude this
  geo tag" (or make `IncludeZeroWeights` configurable, e.g. `ExcludeZeroWeights`
  for weight 0). Small change in the CoreDNS plugin, big value for this pattern.
- Not an alternative: deleting the Gslb in the region. `docs/partial-deployment.md`
  says it explicitly: the region's CoreDNS still answers (NXDOMAIN), so clients
  get inconsistent answers. "Not a safe way to exclude a cluster".

## 2. (removed)

Istio was part of the first versions of the demo and was dropped: it only remains because k8gb's local setup installs it as the Gateway API
implementation, and the demo neither manages nor upgrades it.

## 3. Kargo: how the pipelines are wired, and what had to change

### Shape: one independent branch of three stages per region

```
 Warehouse ─┬▶ eu-drain ─▶ eu-upgrade ─▶ eu-restore
            ├▶ us-drain ─▶ us-upgrade ─▶ us-restore
            └▶ cz-drain ─▶ cz-upgrade ─▶ cz-restore
```

One project, `kubernetes`; the drain/restore stages are generic (they only call the `set-rotation`
`ClusterPromotionTask`) and could drive any other pipeline; only `<region>-upgrade` and the Warehouse are
specific to Kubernetes. Each stage is verified by an Argo Rollouts `AnalysisRun` (a Job in the Kargo project namespace):
`dns-region-absent`, `gateway-smoke`, `dns-region-present`. The node check of the upgrade is a Promotion step
(§8). The Argo CD sync is Kargo's own `argocd-update` pinned to the commit it just pushed.

Branches are a choice for readability, not safety: nothing in the shape keeps two regions from
draining at once, which would leave nobody serving. The `set-rotation` task therefore carries an
**interlock made of upstream steps only**: `yaml-parse` reads `gslb/rotation.yaml`, `fail` aborts if another
region is already drained (the annotation `region-upgrades-drained` is the lock: one value for the whole system), and `argocd-wait` holds the
drain until every Argo CD Application of the other regions (selected by label) is Synced and Healthy. `scripts/rollout.sh` runs regions one at a time.
**Tested** with three regions (`evidence/three-regions-run/guards-refused.json`): with `eu` drained by hand, promoting `us-drain` failed at the
`fail` step with *"refusing to drain us: eu is drained right now"*; the rotation did not change. The `argocd-wait` half was seen working by accident:
a drain stayed in its wait step for about 4 minutes because another region's Plan was still `Complete=False`, and went on the moment that region
was Healthy again. Not tested: two drains started at the same instant (a race between two clones of the repo; Git's push would refuse one of them).

### What works upstream, as designed

`argocd-update` with a pinned `desiredRevision` plus Verification works **because the Verification
starts right after the Promotion, while the pins are still valid**. After later commits the Stage's
health check goes stale (the Application's observed revision moved on) and the Stage shows unhealthy
afterwards; that is cosmetic, the Freight is already verified.

### What does not, and the workarounds

* **`argocd-update` never prunes** (it copies only `retry` and `syncOptions` into the operation,
  `pkg/promotion/runner/builtin/argocd_updater.go`). Seen when a bad config was reverted: it stayed in the region. `automated.prune: true` alone is not enough (Argo CD does
  not retry a revision a sync already handled); **`prune` + `selfHeal`** is. In `gitops/argocd/appset-*.yaml`.
* Verification needs the **Argo Rollouts controller and all its CRDs** (also `rollouts`, `experiments`,
  or its informers never sync): Kargo creates AnalysisRuns but does not run them.
* Kargo refuses Git credentials over plain HTTP: `controller.allowCredentialsOverHTTP: true` for the
  in-cluster Gitea (demo shortcut).
* **Kargo only verifies Freight for a Stage that is Healthy, and may do it too early.** In the first
  Kubernetes run `eu-upgrade` was marked verified 17 s into an upgrade that took about 45 s more
  (Argo CD's health was still the state from before the Plans changed). The restore did wait,
  but only because of internal auto-promotion behaviour I do not want to rely on. So the Kubernetes
  check asks the **nodes** directly from inside the Promotion (§8), with a read-only credential.
* After a failed Promotion, re-promoting the same or a fixed Freight works because every step is
  idempotent: `git-commit` with nothing to commit is **Skipped** and still outputs HEAD.
* Argo CD Applications that Kargo updates need `kargo.akuity.io/authorized-stage`. The `gslb-*` apps are
  updated by every drain/restore stage, so the annotation lists all four.

### Smaller things that bit

* Every `git-clone` in one Promotion shares a work directory: use distinct paths per use of a task.
* Warehouse `allowTags` was removed in Kargo 1.11: use `allowTagsRegexes` (a list).
* `git-clone` has no `fromFreight` in v1.12.5 (the expressions docs show it): use
  `commit: ${{ commitFrom(repoURL).ID }}`.
* `${{ }}` values containing `: ` (ternaries) must be quoted, and `${{ }}` inside a YAML flow
  mapping (`{a: ${{ x }}}`) breaks the YAML: use block style.
* A `Promotion` can't use `generateName: eu-drain.` (trailing dot); `scripts/promote.sh` names it.
* The Git repo is an in-cluster Gitea, so no GitHub account or token.
* podinfo is the demo workload, not a pipeline: an application release is a job for a canary.

## 4. Environment gotchas (laptop)

- Colima VM: 4 k3s clusters hit `fs.inotify.max_user_instances=128` →
  containerd "too many open files", the mgmt node never registers. `make preflight`
  raises it (not persistent across a VM restart).
- Colima memory: 10 GB was not enough for edge + 2 regions + mgmt; set to 14 GB.
- Flaky registry access (ghcr.io, docker.io, github.io, from the VM) made
  `make base-up` fail repeatedly. `scripts/base-up.sh` and `scripts/bootstrap.sh`
  retry and are idempotent. A VPN (Twingate) was involved in some of it.
- `helm repo update` fails as a whole if one *unrelated* repo in the user's Helm
  config is unreachable (k8gb's Makefile runs it). Our scripts update only the
  repos they need.
- macOS: the IPs k8gb returns are docker-network IPs, not routable from the host.
  `watch.sh` probes from a container on `k3d-action-bridge-network`.
- From inside mgmt, regional API servers are reachable as
  `https://k3d-test-gslbN-serverlb:6443` (TLS SAN works), edge DNS as
  `k3d-edgedns-server-0:30053`.

## 5. M5 (exploration): k8gb upgrading k8gb

Done with `scripts/k8gb-experiment.sh` and plain `helm upgrade` on the k8gb release
of one region, with that region drained through the same Git-driven rotation as
everywhere else. **There is no Kargo/Argo CD pipeline for k8gb yet**: Argo CD
would first have to adopt k8gb's Helm release (many values), which wasn't worth it
before knowing what the upgrade does. The raw outputs are in `evidence/m5-k8gb-*.txt`.

N-1 → N is chart `v1.0.0` → `v1.0.1` (operator `v1.0.0` → `v1.0.1`, CoreDNS
`k8s_crd` `v0.6.0` → `v0.7.0`). CRDs are identical between the two charts
(`diff -r chart/k8gb/crd`), and the chart renders them from
`templates/crds-template.yaml`, so Helm upgrades them and Argo CD would apply them
as ordinary manifests (this last part not tested through Argo).

Gotcha that cost me a wrong first run: the installed release pins
`k8gb.imageTag: v1.0.1` (k8gb's Makefile sets it). `helm upgrade --reuse-values
--version v1.0.0` then swaps the chart templates but **keeps running the v1.0.1
images**. Set the operator and CoreDNS image tags explicitly per version. The first
run (templates v1.0.0, images v1.0.1) even gave inconsistent answers from eu's
CoreDNS during a drain; discard it.

Probes: one DNS query every 0.2 s against the edge BIND (what resolvers see) and
against each region's CoreDNS directly, plus `watch.sh` for app traffic.

### Happy path (eu drained, k8gb eu v1.0.0 → v1.0.1)

```
helm upgrade eu took 35 s (pod replacement + --wait)
[edge]        448 NOERROR (2 records: us only)    6 NOERROR (4 records)    0 failures
[eu-coredns]  299 NOERROR (2 records)            49 TIMEOUT
[us-coredns]  458 NOERROR (2 records)
```

- **App traffic: 0 errors.** The drain covers the app role.
- **DNS: users saw no failure either**, but only because the edge BIND shielded
  them: eu's own CoreDNS timed out for part of the upgrade (49 of 348 queries) and
  BIND answered from us instead.
- 6 of 454 edge answers (1.3%) still contained eu's addresses: the first seconds
  after the drain (TTL) and/or the restart window; not isolated further.
- us's operator logged `can't resolve FQDN using nameservers` warnings for about
  30 s while eu's CoreDNS was down, then recovered by itself.

### Version skew (eu v1.0.1, us v1.0.0, both in rotation, 60 s)

Nothing broke: edge, eu-coredns and us-coredns all returned 4 records on every
query (274/274); both `Gslb` showed the same healthy records. Only the transient
warnings above.

### Failure path (eu drained, k8gb in eu broken)

```
(a) operator stops publishing, records gone from eu's CoreDNS  (answers NXDOMAIN)
    [edge] 188 NXDOMAIN of 188      [eu-coredns] 188 NXDOMAIN      [us-coredns] 184 NOERROR
    watch.sh: 84 failed requests (clients could not resolve the host)
(b) eu's CoreDNS down (crash loop / bad build)
    [edge] 121 NOERROR (2 records)   61 NXDOMAIN   [eu-coredns] 60 TIMEOUT   [us-coredns] 185 NOERROR
```

**This is the gap.** With eu drained and us perfectly healthy, a k8gb in eu that
*answers wrongly* made the edge BIND return NXDOMAIN for **100%** of the queries
for over a minute, and real clients failed (84 errors; the only errors in all of
M5). BIND sticks to the nameserver it prefers (best RTT) and does not fail over on
a negative answer. A CoreDNS that is simply *down* is much better: BIND times out
and moves to us's nameserver (the 61 NXDOMAIN in (b) are most likely the negative
cache of (a), TTL `dnsZoneNegTTL: 10`, not a (b) effect; not isolated).

So **the drain protects the app role but not the nameserver role**, and a bad k8gb
upgrade attacks exactly the nameserver role. For k8gb itself the pattern needs
a DNS-layer drain, or a canary of the k8gb upgrade that is verified through the
resolvers' path before the region is trusted.

### DNS-layer drain: is there a declarative way?

No. Code: `controllers/providers/k8gbendpoint/delegationDNSEndpoint.go` publishes
`<zone> NS [gslb-ns-<geo>-<zone> ...]` (TTL `nsRecordTTL`, default 30 s) from
`ExtendedZoneDelegation.GetActiveNSServerList()`, which is built from
`ZoneDelegation.status.dnsServers`: a nameserver is in the set when its glue was
discovered. The `ZoneDelegation` spec is only `{dnsZoneNegTTL, doFinalize,
loadBalancedZone, parentZone}`: no maintenance/drain switch. `docs/partial-deployment.md`
adds that deleting the Gslb is not a safe way to exclude a cluster.

Sketch of an upstream change (not implemented): a field on `ZoneDelegation`
(e.g. `spec.drained: true`, or an annotation) that makes the local cluster
publish an empty/removed NS entry and stop answering authoritatively for the zone,
declared in Git like the rotation. Cost to expect: the NS TTL (30 s here) plus
resolver caching; resolvers that cached the NS set keep asking the drained
nameserver until it expires, so the drain order is: DNS-layer drain, wait ≥ NS TTL,
then upgrade k8gb.

## 6. Measured numbers

The newest numbers, with three regions, are in §10 (`evidence/three-regions-run/`). The first two-region run (k3s 1.36.2 → 1.37.2, 1286 requests,
2 failed, both in the control) gave:

| Scenario | Wall time | Client errors |
|---|---|---|
| Kubernetes 1.36.2 → 1.37.2 of **eu, no drain** (control) | 3 min 23 s | **2** of 278 requests |
| Kubernetes 1.36.2 → 1.37.2 of **us, through the pipeline** | 1 min 49 s | **0** |

Be careful what the control shows. The two failures happened at 08:34:07, when the eu agent
node was drained; k8gb's own health check removed eu from DNS about one second later and
the errors stopped. With one request per second, two app pods and a tiny workload, the damage of
upgrading without a drain is small here. It is real (a failed request, a dropped connection) and
a drain makes it zero, but this is **not** evidence of an outage. Long-lived connections, many
clients and real load would probably make the difference larger, which is exactly what this test
does not cover (see §7).

The failure path (an upgrade that cannot complete, then the fix) is in §10. What it showed: the explicit failure only exists because the node check
is part of the `<r>-upgrade` Promotion (a native `http` step, §8); with the check as a Verification, a Promotion whose Argo CD health is stale
"Succeeded" at once and the chain stalled silently.

Kubernetes pipeline per stage, us (Kargo's timestamps, `scripts/timings.sh kubernetes`):

```
stage      promotion_s  verification_s  total_s
us-drain          3            13           16     edge DNS stopped returning us
us-upgrade        6            18           81     Plans applied; Kargo waits for Argo CD, then the nodes check
us-restore        1             9           10
```

`us-upgrade` is 81 s because Kargo only starts the verification once the Stage is Healthy (the Plans
Complete) and the Plans take about 55 s to roll the server and the agent.

`watch.sh` excerpt, Kubernetes upgrade of us through the pipeline (the headline):

```
08:35:20  dns=[eu]    answer=eu  k8s=eu:v1.37.2,us:v1.36.2  err=2 <- dns: [eu,us] -> [eu]        us drained
08:35:52  dns=[eu]    answer=eu  k8s=eu:v1.37.2,us:v1.37.2  err=2 <- k8s: ... us:v1.36.2 -> us:v1.37.2
08:36:50  dns=[eu,us] answer=eu  k8s=eu:v1.37.2,us:v1.37.2  err=2 <- dns: [eu] -> [eu,us]        us restored
```

Kubernetes changes in a region only while that region is out of DNS; `err` does not move.

Drain latency: the edge DNS stopped returning the region within about 5 s of the Git push in the manual
run, and the drain verification needs 9-13 s including its 5 consecutive clean answers, with
`dnsTtlSeconds: 5`. Production TTLs, and resolver caches that ignore them, make a real drain much longer.

### `weight: 0` with the patched CoreDNS (the upstream proposal, tried live)

`scripts/k8gb-dropzero-demo.sh`, evidence `evidence/k8gb-dropzero.txt`. Gslb `roundRobin`,
`weight: {eu: 0, us: 1}`, no `failover`:

```
upstream CoreDNS    all four addresses in every answer; eu's last (CoreDNS), first in about half of the edge answers
patched + dropzero  eu coredns 12/12, us coredns 12/12, edge BIND 12/12: only 172.18.0.11 172.18.0.12
```

So a drain becomes a plain weight change and works for any number of regions.

**Observed twice, cause not found: k8gb's operator stopped reconciling the `Gslb`.** Its log then shows only
the `ZoneDelegation` loop (the `Gslb` loop normally logs every 10 s), the `Gslb` has an empty `status:` and the
`DNSEndpoint` stops changing. First time: after a `Gslb` with `roundRobin`, `primaryGeoTag` and `weight` was
applied, the weight labels never appeared; it resumed when I changed the `Gslb` again (removing `primaryGeoTag`).
Second time: after restoring `roundRobin` through Git, eu stayed out of the DNS answers for over five minutes
although the `Gslb`, Argo CD and eu's `localtargets-` were all right; `kubectl rollout restart deploy/k8gb` in eu
fixed it at once. It happened after a long session of spec changes and a CoreDNS swap, never in the dozens of
rotation changes of the earlier runs, so I cannot say it is a bug in k8gb rather than something I did. It is
noted because a drain that does not come back is the failure this pattern must not have: a restore should
be verified (the `dns-region-present` verification does that) and k8gb's operator is worth restarting first
when it does not.

## 7. Not done / honest gaps

* **The cost of not draining is measured on a tiny workload** (§6). Nothing here covers long-lived
  connections, many clients, resolvers that ignore TTLs, or a region that must absorb the other's load (N-1).
* No Kargo/Argo pipeline for k8gb itself (M5 was run with plain Helm); a DNS-layer drain is missing (§5).
* Three regions, not more. The `failover` drain works with three but gives ALL the traffic to one receiver and takes the third region out too (§10); the `dropzero` patch (§6) would divide it. Nothing was tried with four or more.
  The patched CoreDNS is a local build, not something the demo depends on.
* The Kubernetes pipeline upgrades k3s in k3d. The k3s-upgrade workaround (§8) is for k3d only; on real
  nodes drop it. A real Kubernetes upgrade also involves add-on compatibility, API removals and etcd, which
  k3d hides. Nothing about add-on or API compatibility with the new version was tested.
* Nothing in `gitops/` is signed or reviewed through PRs: Kargo commits straight to `main` of the
  in-cluster Gitea. A real setup would use PRs (`git-open-pr`).
* Kubernetes does not support a downgrade, so `make reset` keeps the version overlay in Git
  (`KEEP_VERSIONS=1`); use `make down && make up` to start again.
* Demo-grade security: Git credentials over HTTP, admin accounts, a long-lived read-only verifier token.
* Nothing was filed upstream; the tested CoreDNS patch is in `tools/coredns-dropzero/`.

## 8. Kubernetes upgrade with System Upgrade Controller

* In-place k3s upgrades are what the k3s project ships: **System Upgrade Controller** watches `Plan`
  resources (`spec.version`), cordons (and for agents drains) a node, replaces the k3s binary and restarts it.
  Plans in Git, applied by Argo CD, make the Kubernetes version a declared per-region setting. The Kargo
  Freight is the `rancher/k3s-upgrade` image tag. Tried first on a throwaway k3d cluster: v1.36.2 → v1.37.2
  in about 50 s, the server first, the agent after (its Plan waits for the server's).
* **Bug in `k3s-upgrade` on k8gb's clusters** (k3s-upgrade, not k8gb): its script finds the k3s
  process by looking for "k3s" in the *parent's* command line. k8gb's clusters start with
  `--node-label svccontroller.k3s.cattle.io/enablelb=true`, which matches, so it takes `/bin/sh` for the k3s
  binary and overwrites it; the node container then restart-loops with `No help topic for
  '/bin/k3d-entrypoint.sh'`. It broke both regional clusters the first time. Worked around in the Plans with a
  one-line `sed` in `spec.upgrade.command`. It does not reproduce on a k3d cluster without that label.
* Even a Plan at the version the node already runs replaces the binary once, so the first sync restarts
  each regional server once (cosmetic, but it can make that first Argo CD sync fail with "apiserver not ready":
  `scripts/sync.sh` retries).
* Argo CD calls a `Plan` Healthy the moment it exists; a custom health check (`argocd-values.yaml`) keeps it
  Progressing until `Complete` and `status.latestVersion == spec.version`. Argo CD omits `health` for healthy
  resources in `status.resources`, so "which message" cannot be read back, and its health can lag the change.
  The check therefore asks the region's **API server** (read-only token, `nodes get/list`, created by
  `scripts/register-clusters.sh`, kept in `.secrets/` and a Secret) that every node runs the target version, is
  Ready and uncordoned. It is a native `http` step at the end of the `<r>-upgrade` **Promotion**, polling with
  `retry` (timeout 6 min), not a Verification: a Verification only runs if the Stage is Healthy, and with a
  stale Argo CD health a bad version made the Promotion "Succeed" and the chain silently stall. As a
  Promotion step a bad upgrade fails loudly (`Errored`, message names the step) and the region stays drained.
  The Verification that follows only runs the direct gateway test. The token is read with
  `secret('region-verifier')` (a function; `secrets[...]` does not exist in Kargo 1.12).
* **Fixing forward is not automatic.** When the Plan version changes while an apply Job is stuck on the old
  one (here `ImagePullBackOff` on a version that does not exist), SUC does not cancel it, and the new
  Job's pod stays `Pending` because of the pod anti-affinity against the old one. Without help the old Job
  only ends at its deadline (`jobActiveDeadlineSecs`, default 900 s, then the Plan shows `DeadlineExceeded`
  and the node can stay cordoned). Clean-up used here: `kubectl -n system-upgrade delete job <the stuck
  jobs>`; SUC then runs the new ones and uncordons (60 s). Seen in both regions. If a Plan keeps showing
  `Complete=False JobFailed` after the node is fine, deleting the Jobs and restarting SUC resets it. This is
  worth a line in any runbook; it is not something the demo hides.
* While the region's API server restarts, `watch.sh` keeps the last version it read.
* The first run found a race I had to fix rather than hide: right after `make up` the edge DNS is still
  converging, and a rollout started then measures a system that is not serving (18 failed requests that were
  not the upgrade's). `make up` now ends with `scripts/wait-ready.sh`.

## 9. (removed)

A variant with two stages per region (the steps inside one Promotion, gated by a small probe service instead of Verifications) worked but cost
about 70 lines of CGI with RBAC and could not keep `argocd-update`; it was dropped for the current design (§3).

## 10. Three regions (eu, us, cz), and a Warehouse you choose from

Added on request after the two-region demo. The third region is k8gb's own `test-gslb3` / geo tag `cz`.

**What `failover` does with three regions** (`scripts/k8gb-three-regions.sh`, evidence
`evidence/three-regions-spike/modes.txt`; code: `controllers/providers/k8gbendpoint/applicationDNSEndpoint.go`,
commit `901a4f2`). First address returned over 12 queries, and the regions in a full answer, edge DNS and each CoreDNS:

| Mode | Answer |
|---|---|
| roundRobin | cz, eu, us in every answer, first address spread over all three |
| failover, primary `us` | **only us**, from all four resolvers. eu AND cz are out: the receiver takes 100% |
| failover, primary `eu` with eu's workload **unhealthy** | **us + cz share** eu's traffic. This is what a maintainer described ("failover splits the drained region's traffic over all the others"): true, but only when the primary is unhealthy (no ready pods), which is not a drain you can verify |
| roundRobin `weight: eu 0` (stock CoreDNS) | eu **still in every answer**; the edge BIND put it first 4 times in 12 |
| same, CoreDNS with `loadbalance weight dropzero` (our patch) | **only us + cz**, split evenly; with weights `us 3, cz 1`: 24/16 of 40 |

So with stock k8gb a drain with three regions means "one receiver serves everybody". The pipeline therefore takes a
**receiver** per region (eu→us, us→cz, cz→eu, a variable of the drain stage) and `rotation.yaml` records which region is
drained in the annotation `region-upgrades-drained` (the lock: the drain refuses if another region is drained, and waits for
the Applications of every other region to be Healthy). The honest costs: the receiver must absorb 100%, and the
third region is unavailable during the drain. The weights mode with the `dropzero` patch removes both, at the price of a CoreDNS
that is not upstream yet.

**Run (three regions, 1.35.9 → 1.36.6 through the pipeline; 1.36.6 → 1.37.2: cz as the no-drain control, eu and us through the pipeline).**
`evidence/three-regions-run/`: 2784 requests at one per second, **4 failed, all in the no-drain control of cz**
(14:51:49-14:51:57, the agent being drained; k8gb took cz out of DNS two seconds later). Everything that went through the pipeline,
including a failed upgrade and its fix, had 0 failed requests. Each region's branch took about 1 min 40 s (drain, upgrade, restore).
The drain shows as `dns=[us]` for eu, `dns=[cz]` for us, `dns=[eu]` for cz.

**Warehouse.** One Warehouse, `k3s`, on `docker.io/rancher/k3s-upgrade` (`>=1.35.0-0`). Kargo creates a Freight only for the newest
match, so the Freight list is the "a newer version exists" notification, and `scripts/freight.sh sync` (`make freight-sync`) adds a Freight for the
newest patch of every minor discovered, because Kubernetes goes one minor at a time. **One Warehouse per minor was tried and is dangerous:**
a Stage that takes Freight from several Warehouses autopromotes, downstream, every origin it holds upstream; in our test `eu` went
from 1.35.9 to 1.37.2 (skipping 1.36) although only 1.36.6 had been chosen (`evidence/three-regions-run/multi-origin-hazard.txt`).
The drain and upgrade stages now also **refuse a skipped minor or a downgrade** (parsing the version in the region's Plan in Git);
both refusals were tested (`evidence/three-regions-run/guard-skip-minor-refused.json`, `guards-refused.json`). A `fail` step needs
`success() &&` in the `if` of every later step, or those steps still run after the failure (an `if` replaces the default).

**What bit, new with three regions (all in `scripts/refresh-addresses.sh`, `DEMO.md` §11):** Docker can give a container another IP when it is
restarted, and the nodes restart (the first sync of the Plans replaces the k3s binary even at the same version). Then: Argo CD cannot
reach a region (the mgmt CoreDNS has container IPs from creation time), a k3d load balancer or a k3s agent may dial another cluster's
node (x509 errors, NotReady), the regions' CoreDNS lose `host.k3d.internal` (k3s rewrites NodeHosts) so k8gb's external-dns cannot
publish to the edge, and the edge zone keeps wrong glue records until that is repaired (2-3 minutes). It never happened in the
two-region runs. The setup now syncs the Plans one region at a time and repairs the addresses afterwards. Not solved: addresses can still
change during a real upgrade round; run `scripts/refresh-addresses.sh` after it (`make ready` does).

The pipeline's node check (`http` step) now has `errorThreshold: 60`: it failed on its first connection error ("EOF") while the region's API server restarted.

**Failure path with three regions** (`make demo-kubernetes-bad`, eu): the bad build is the running version with build `k3s99`
(`v1.37.2-k3s99`), so the skip-minor / downgrade check lets it through and the fix, back to the real `v1.37.2-k3s1`, passes it too.
`eu-upgrade` errored after 6 minutes (`step "step-10" timed out after 6m0s`), eu stayed drained (`dns=[us]`), 0 failed requests. Fix: the
stuck Jobs were deleted and the cordoned server uncordoned by hand (the Plan went back to a hash SUC had already completed, so it ran
nothing and left the cordon), then `scripts/retry-from-upgrade.sh`. Re-promoting a Freight a Stage already holds does not continue
the branch by itself: the restore has to be promoted too, which that script does.
