# Walkthrough

Step by step: what to run, what to look at, what each script does. Background and measurements: [README.md](README.md), [NOTES.md](NOTES.md).

Regions: **eu** (`k3d-test-gslb1`), **us** (`k3d-test-gslb2`), **cz** (`k3d-test-gslb3`). Also `k3d-mgmt` (Argo CD, Kargo, Gitea) and
`k3d-edgedns` (the parent DNS, BIND). Kubernetes starts at **k3s v1.35.9** and cannot be downgraded: to start over use `make down up`.

## 1. Start

```sh
make up        # 15-20 min, ends when every Application is healthy and the edge DNS answers for all three regions
```

`make up` = `base-up` (the k8gb clusters, k3s v1.35.9) → `bootstrap` (mgmt cluster) → `tools-image` → `wire` (registers the regions, seeds Git,
creates the Applications, first sync) → `kargo` (Warehouse and stages) → `freight-sync` → `ready`. Each target can be run alone and resumes.

Check it:

```sh
kubectl --context k3d-mgmt -n argocd get applications            # 9, all Synced and Healthy
for c in 1 2 3; do kubectl --context k3d-test-gslb$c get nodes; done      # all v1.35.9
dig @127.0.0.1 -p 1053 podinfo.cloud.example.com +tcp +short     # 6 addresses: 2 per region
```

In a second terminal, and leave it running:

```sh
make watch
```

```
14:41:17  dns=[us]  answer=us  k8s=eu:v1.35.9,us:v1.35.9,cz:v1.35.9  err=0 <- dns: [cz,eu,us] -> [us]
```

`dns=` regions the edge DNS returns now · `answer=` region that answered · `k8s=` version per region · `err=` failed requests so far (should stay put) · `<-` a change.

UIs: `make ui-kargo` (https://localhost:8082) and `make ui-argocd` (http://localhost:8081); both print the admin password.
In Kargo, project `kubernetes`: promote a Freight to a region's `<r>-drain` stage (drag and drop works) and the rest of that branch follows.

## 2. The Freight list

```sh
make freight
```

A Freight is a k3s version you can install. The Warehouse creates one for the newest version it finds, so the list is your "a newer version exists"
notification; `make freight-sync` adds the newest patch of every minor (v1.35.10, v1.36.6, v1.37.2), because Kubernetes goes one minor at a time.
Nothing rolls out until you promote one. `./scripts/freight.sh discovered` shows everything the Warehouse found.

## 3. Upgrade 1.35 → 1.36, region by region

```sh
./scripts/promote.sh kubernetes eu v1.36.6-k3s1      # starts eu-drain; the rest of the branch follows
```

In the watch (about 2 minutes): `dns=[us]` (eu leaves; with `failover` the receiver serves everybody, so cz is out too) → `k8s: eu:v1.35.9 -> eu:v1.36.6`
(eu changes while it receives nothing) → `dns=[cz,eu,us]` (eu is back). `err` does not move.

```sh
./scripts/pipeline-status.sh kubernetes                       # phase of every stage
kubectl --context k3d-test-gslb1 get nodes                    # server first, then the agent (drained)
kubectl --context k3d-test-gslb1 -n system-upgrade get plans  # System Upgrade Controller
./scripts/timings.sh kubernetes v1.36.6-k3s1                  # how long each stage took; the drain verification is the measured drain
```

What each stage does:

| Stage | Promotion | Verification |
|---|---|---|
| `eu-drain` | refuses a skipped minor or a downgrade; sets `gslb/rotation.yaml` to `failover` (receiver `us`, drained region `eu`) after checking nothing else is drained and the other regions are healthy; Argo CD applies it | the edge DNS no longer returns eu (5 clean answers in a row) |
| `eu-upgrade` | sets the version in eu's two `Plan`s; Argo CD applies them; an `http` step asks eu's API server (read-only token) until all nodes run the new version, are Ready and not cordoned, or fails after 6 min | eu's gateway answers 200 with the right app, called directly |
| `eu-restore` | `roundRobin` again | the edge DNS returns eu |

The other regions, one at a time (`us` and `cz`), or all three in turn:

```sh
./scripts/rollout.sh kubernetes v1.36.6-k3s1 us cz           # make demo-kubernetes VERSION=v1.36.6-k3s1 does eu, us and cz
```

## 4. The control: the same upgrade without a drain

From 1.36 to 1.37, **cz first, without drain**, then the other two through the pipeline:

```sh
make demo-kubernetes-nodrain REGION=cz VERSION=v1.37.2-k3s1     # edits the Plans in Git, no Kargo, cz stays in DNS
./scripts/refresh-addresses.sh                                   # restarted nodes may get new addresses
./scripts/rollout.sh kubernetes v1.37.2-k3s1 eu us
```

In the watch cz stays in rotation (`dns=[cz,eu,us]`) while its nodes restart. In our run 4 requests failed, when cz's agent was drained, until k8gb removed cz from DNS
on its own about two seconds later. The drain's value is making that zero and covering failures k8gb cannot see (pods ready, answers wrong).

## 5. What gets refused

```sh
./scripts/promote.sh kubernetes eu v1.37.2-k3s1      # (with eu at 1.35.9) skips a minor
kubectl --context k3d-mgmt -n kubernetes get promotions -o json | jq -r '.items[]|"\(.spec.stage) \(.status.phase) \(.status.message)"'
# eu-drain Failed ... refusing to drain eu: it runs v1.35.9-k3s1 and Kubernetes upgrades one minor at a time, so v1.37.2-k3s1 would skip a minor.
```

DNS is not touched (it refuses before the drain). The same check is in `<r>-upgrade`; going back (for example v1.36.6 on a region at 1.37.2) is refused as a downgrade.

**Interlock:** two regions are never out at once. With eu drained, draining us fails:

```sh
make drain REGION=eu
./scripts/promote.sh kubernetes us v1.37.2-k3s1      # Failed: refusing to drain us: eu is drained right now
make restore REGION=eu
```

## 6. An upgrade that cannot complete

```sh
make demo-kubernetes-bad            # REGION=eu by default
```

The Freight is the version the region runs now with a build number that was never published (`v1.37.2-k3s99`). The nodes never get there, so after 6 minutes the
`eu-upgrade` Promotion errors (`step "step-10" timed out after 6m0s`), `eu-restore` never starts, **eu stays out of DNS** and the others serve; `err` does not move.

```sh
kubectl --context k3d-test-gslb1 get nodes                      # the server is cordoned
kubectl --context k3d-test-gslb1 -n system-upgrade get pods     # ImagePullBackOff
```

Clean up what the failed upgrade left (System Upgrade Controller does not cancel a stuck Job, and the node stays cordoned), then fix:

```sh
kubectl --context k3d-test-gslb1 -n system-upgrade delete jobs --all
kubectl --context k3d-test-gslb1 uncordon k3d-test-gslb1-server-0        # only if the node shows SchedulingDisabled
make demo-kubernetes-fix                                                   # promotes eu-upgrade and eu-restore with the real Freight
```

(A Freight a stage already holds is not promoted again by itself, hence the two explicit promotions.)

## 7. Manual drain, without Kargo

```sh
make drain REGION=eu                  # commits gslb/rotation.yaml; receiver us (make drain REGION=eu RECEIVER=cz)
dig @127.0.0.1 -p 1053 podinfo.cloud.example.com +tcp +short    # edge: only the receiver's addresses
dig @127.0.0.1 -p 5053 ... ; dig @127.0.0.1 -p 5054 ... ; dig @127.0.0.1 -p 5055 ...    # eu's, us's, cz's own CoreDNS
make restore REGION=eu
```

## 8. k8gb with three regions, DNS only (optional)

What do `failover`, `weight: 0` and the proposed `dropzero` do with three regions? Run it after `make base-up` and **before** `make wire`
(Argo CD would revert the manual changes):

```sh
make base-up
./scripts/k8gb-three-regions.sh       # about 8 min: deploys podinfo and a Gslb straight into the three clusters, measures, cleans up
make bootstrap tools-image wire kargo freight-sync ready
```

It prints, for the edge DNS and each region's CoreDNS, the region of the first address over 12 queries and the regions in a full answer. Results
(`evidence/three-regions-spike/modes.txt`):

| Mode | The DNS returns |
|---|---|
| `roundrobin` | all three regions |
| `failover-us` (primary us) | **only us**: eu and cz are both out |
| `failover-eu-down` (primary eu, its workload unhealthy) | us and cz share eu's traffic (but eu cannot be verified while drained) |
| `weight0` (`eu:0 us:1 cz:1`, stock CoreDNS) | **eu still in the answers**, last; first 4 times in 12 at the edge |
| `dropzero` (same weights, patched CoreDNS) | only us and cz, 50/50; with `us:3 cz:1`, 24/16 of 40 |

`dropzero` needs the patched CoreDNS built once: `PLUGIN_DIR=<checkout of k8gb-io/coredns-crd-plugin> ./scripts/k8gb-dropzero-demo.sh build`
(patch and tests: `upstream/coredns-crd-plugin/`).

## Scripts

| Script | What it does |
|---|---|
| `base-up.sh` | creates edgedns + the three regional clusters from k8gb's own k3d configs, with the k3s image replaced by v1.35.9 (`./k8gb` is never touched), installs k8gb |
| `bootstrap.sh` | mgmt cluster: cert-manager, Argo CD, Gitea, Argo Rollouts, Kargo; passwords go to `.secrets/` (not in Git) |
| `register-clusters.sh` | registers the regions in Argo CD by Docker name, creates a read-only node-reader account per region, writes `.secrets/regions.env` and `verifier.env` |
| `seed-git.sh` | creates the Gitea repo and pushes `./gitops` as a fresh history (running it again resets the repo) |
| `sync.sh <app>...` | syncs Argo CD Applications and waits for `Synced` + `Healthy` |
| `kargo-apply.sh` | applies the drain/restore task, verification templates, the project; creates the Git and `region-verifier` Secrets |
| `refresh-addresses.sh` | re-learns container addresses after Docker changed them (see Troubleshooting); `make ready` runs it |
| `wait-ready.sh` | waits for healthy Applications and a DNS answer with all three regions, 10 queries in a row |
| `freight.sh` | `list`, `discovered`, `sync`, `create <tag>` |
| `promote.sh <project> <region> <freight\|version> [drain\|upgrade\|restore]` | promotes a Freight to a stage of a region's branch (the optional stage retries a failed one) |
| `rollout.sh <project> <freight\|version> [region...]` | `promote` + wait, one region at a time (default eu, us, cz) |
| `wait-pipeline.sh` · `pipeline-status.sh` · `timings.sh` | follow a branch until restore is verified · stage phases · stage durations |
| `retry-from-upgrade.sh <region> <freight\|version>` | promotes `<r>-upgrade` then `<r>-restore` and waits for each (the fix after a failure) |
| `bad-k3s-freight.sh create\|good [region]` | the failure path: a Freight for a build that does not exist; the real one |
| `k8s-nodrain.sh <region> <version>` | the control: the same change in Git, without drain or Kargo |
| `rotation.sh drain\|restore <region> [receiver]` | manual drain/restore by editing `gslb/rotation.yaml` |
| `watch.sh` | the live view (`DURATION=<s>`, `LOG_CSV=<file>`; one at a time, or set `WATCH_CONTAINER`) |
| `k8gb-three-regions.sh` · `k8gb-dropzero-demo.sh` · `k8gb-experiment.sh` | k8gb experiments outside the pipeline: this section 8 · the patched CoreDNS (two regions) · upgrading k8gb itself with Helm (NOTES.md §5) |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `make preflight`: host ports in use | another local cluster holds them: stop it |
| pods evicted, Plans stay `Progressing`, node `DiskPressure` | the Docker disk is over 85% full: free space or `colima start --disk 140` |
| mgmt node does not register, "too many open files" | VM inotify limit: `make preflight` raises it (not persistent across a Colima restart) |
| `make up` times out on ghcr.io or github.io | flaky network: scripts retry; run `make up` again, it resumes |
| a region `Unknown` in Argo CD, "no route to host", a node `NotReady` with `x509: certificate signed by unknown authority`, a region missing from DNS | Docker changed container IPs when nodes restarted: `./scripts/refresh-addresses.sh`; the edge DNS records catch up in 2-3 minutes |
| after a failed upgrade the node stays cordoned / the `Plan` is `Complete=False` | delete the Jobs in `system-upgrade`, restart `deploy/system-upgrade-controller`, `kubectl uncordon <node>` |
| no Freight right after `make up` | the Warehouse is still on its first discovery (1-3 min): `make freight-sync` waits for it |
| a failed stage is re-promoted and nothing happens | a Freight a stage already holds is not promoted again: `./scripts/promote.sh kubernetes <region> <version> upgrade` |
| a region does not come back to DNS after restore | the k8gb operator may have stopped reconciling the `Gslb`: `kubectl --context k3d-test-gslb1 -n k8gb rollout restart deploy/k8gb` |
| a server restart-loops with `No help topic for '/bin/k3d-entrypoint.sh'` | a `Plan` without the k3d workaround overwrote `/bin/sh` (`upstream/k3s-upgrade-k3d.md`): `make down up` |

`make reset` puts rotation and Kargo back at the start but keeps the Kubernetes version; `make down` removes everything this repo created.
