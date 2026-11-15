# Evidence

Raw output behind the numbers in `NOTES.md`.

| Path | What |
|---|---|
| `three-regions-run/` | the full three-region run: 1.35.9 → 1.36.6 → 1.37.2, no-drain control, refused upgrades, failure path and fix; 2784 requests, 4 failed, all in the control |
| `three-regions-spike/modes.txt` | what `failover`, `weight: 0` and `dropzero` do with three regions (`scripts/k8gb-three-regions.sh`) |
| `k8gb-dropzero.txt` | the patched CoreDNS (`loadbalance weight dropzero`) tried live, two regions |
| `m5-k8gb-*.txt` | upgrading k8gb itself in a drained region: happy path, version skew, a broken k8gb (NOTES.md section 5) |
