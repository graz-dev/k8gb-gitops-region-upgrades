# Kargo: `argocd-update` and Applications that track a branch

*Draft issue. Not filed. Seen with Kargo v1.12.5 and Argo CD v3.6.1.*

## Problems found (seen in every run of the demo; details in NOTES.md section 3)

1. **No prune.** The sync operation Kargo creates copies only `retry` and `syncOptions`
   (`pkg/promotion/runner/builtin/argocd_updater.go`). Removing a file in Git (a reverted bad config)
   leaves the object in the cluster and the Application `OutOfSync`. Workaround: `automated.prune`
   **and** `selfHeal` on the Application (prune alone is not enough: Argo CD does not retry a revision
   a sync already handled).
2. **Without `desiredRevision`, the sync can apply the previous commit.** The step hard-refreshes
   and starts the operation at once; Argo CD has not re-resolved the branch yet.
3. **With `desiredRevision`, every step registers a health check that must match the Application's
   observed revision exactly.** The next commit on the branch (a later step, or another Stage)
   moves it, the earlier checks go stale and the Stage reports unhealthy. Kargo only marks Freight
   verified for a healthy Stage, so a multi-step Promotion that commits more than once never
   becomes verified.

## Suggested changes

* `prune: true` (default false) on the `argocd-update` sync operation.
* Health checks that accept "synced to this revision **or a descendant of it**".
