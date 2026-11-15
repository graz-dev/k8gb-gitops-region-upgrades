#!/usr/bin/env bash
# Apply the Kargo side: the shared promotion task and verification templates, then each
# project (namespace, Git credentials, region addresses, warehouse, stages). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
MGMT=k3d-mgmt
PROJECTS=${PROJECTS:-"kubernetes"}
GIT_USER=gitea_admin; GIT_PASS=$(cat .secrets/gitea-admin-password)
GIT_URL=http://gitea-http.gitea.svc.cluster.local:3000/demo/gitops.git

kubectl --context $MGMT apply -f kargo/cluster/

for p in $PROJECTS; do
  kubectl --context $MGMT apply -f kargo/projects/$p/project.yaml
  until kubectl --context $MGMT get ns "$p" >/dev/null 2>&1; do sleep 1; done

  # Git credentials Kargo uses to clone/push the gitops repo (never in Git)
  kubectl --context $MGMT -n "$p" apply -f - <<EOS
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  namespace: $p
  labels:
    kargo.akuity.io/cred-type: git
type: Opaque
stringData:
  repoURL: $GIT_URL
  username: $GIT_USER
  password: $GIT_PASS
EOS
  # Region addresses for the verification Jobs
  kubectl --context $MGMT -n "$p" create configmap regions --from-env-file=.secrets/regions.env \
    --dry-run=client -o yaml | kubectl --context $MGMT -n "$p" apply -f -

  # Read-only credentials the verification Jobs use to ask each region's nodes (see register-clusters.sh)
  # Promotion steps read it with secret('region-verifier').EU_TOKEN; the generic cred-type label is how Kargo documents such Secrets.
  kubectl --context $MGMT -n "$p" create secret generic region-verifier --from-env-file=.secrets/verifier.env \
    --dry-run=client -o yaml | kubectl --context $MGMT -n "$p" apply -f -
  kubectl --context $MGMT -n "$p" label secret region-verifier kargo.akuity.io/cred-type=generic --overwrite >/dev/null

  kubectl --context $MGMT -n "$p" apply -k kargo/projects/$p
done
echo "kargo applied: $PROJECTS"
