# k3s-upgrade: in k3d, the script overwrites `/bin/sh`

*Draft bug report. Not filed. rancher/k3s-upgrade v1.37.2-k3s1, system-upgrade-controller v0.21.1.*

## Symptom

A `Plan` upgrading a k3d node leaves the node container in a restart loop, with
`No help topic for '/bin/k3d-entrypoint.sh'` in its logs. The k3s binary has been copied over `/bin/sh`.

## Cause

`upgrade.sh` finds the k3s process, then adjusts for a "k3s init" parent:

```sh
if [ "$K3S_PPID" != "1" ] && tr "\0" " " < "/host/proc/${K3S_PPID}/cmdline" | grep k3s | grep -q -v supervise-daemon; then
  K3S_PID="${K3S_PPID}"
fi
# When running in k3d, k3s will be pid 1 and is always at /bin/k3s
if [ "$K3S_PID" = "1" ]; then K3S_BIN_PATH="/bin/k3s"; else K3S_BIN_PATH=$(awk 'NR==1 {print $1}' "/host/proc/${K3S_PID}/cmdline"); fi
```

In k3d the tree is `docker-init (1) -> /bin/sh /bin/k3d-entrypoint.sh ... (7) -> /bin/k3s server (27)`. The
`grep k3s` on the parent's command line matches an **argument**, not the program: k8gb's clusters start with
`--node-label svccontroller.k3s.cattle.io/enablelb=true`. So `K3S_PID=7`, `K3S_BIN_PATH=/bin/sh`.

## Repro

A k3d cluster started with this node label (the same config k8gb's local setup uses), then
`system-upgrade-controller` and a server `Plan` with a newer version:

```yaml
apiVersion: k3d.io/v1alpha4
kind: Simple
metadata: {name: x}
image: docker.io/rancher/k3s:v1.36.2-k3s1
options:
  k3s:
    nodeLabels:
      - label: svccontroller.k3s.cattle.io/enablelb=true
        nodeFilters: [server:*]
```

Without the label the same upgrade works (tried: v1.36.2 to v1.37.2 in about 20 s).

## Suggested fix

Match the program name only (`awk '{print $1}'` of the parent's cmdline), not any occurrence of "k3s".

## Workaround used in the demo

A `Plan` can override the upgrade container's command: the demo patches the one line with `sed`
so that, inside k3d, the binary is `/bin/k3s`. See `gitops/platform/k8s/overlays/*/plan-*.yaml`.
