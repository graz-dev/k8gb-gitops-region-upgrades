# Upstream material (drafts, nothing has been filed)

What this demo found that belongs in the projects it uses, each with the evidence, a suggested
change and its status. Written so a maintainer can read one file without knowing the rest of the repo.
Please review and file them yourself: they are drafts, in the voice of someone who ran the demo.

| # | Project | What | Status |
|---|---|---|---|
| 1 | k8gb (`coredns-crd-plugin`) | `weight: 0` should be able to take a region out of DNS answers | **patch + tests written and passing**, tried in the demo: `coredns-crd-plugin/0001-wrr-optional-dropzero.patch` |
| 2 | k8gb (operator) | no way to take a cluster's nameserver out of the delegation (maintenance) | design sketch |
| 3 | Kargo | `argocd-update`: no `prune`, and pinned revisions make the Stage unhealthy | issue draft |
| 4 | k3s (`k3s-upgrade`) | in k3d, the upgrade script overwrites `/bin/sh` when the entrypoint's arguments contain "k3s" | bug report with a repro |

Files: `k8gb-wrr-drop-zero-weights.md`, `k8gb-zonedelegation-drain.md`, `kargo-argocd-update.md`,
`k3s-upgrade-k3d.md`. Measurements behind them: `../NOTES.md` and `../evidence/`.
