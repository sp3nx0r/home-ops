# Talos 1.14 Workload Isolation (sandboxd) vs. democratic-csi iSCSI

**Status:** Blocked / parked. Enabling `workloadIsolation` breaks all democratic-csi
iSCSI mounts. Waiting for upstream (Talos and/or democratic-csi) to publish a
sandbox-compatible iSCSI recipe before re-enabling.

## Background

Talos 1.14 adds workload isolation via the `SecurityProfileConfig` document:

```yaml
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: true
```

The container plane (CRI containerd, kubelet, and all pods) then runs inside a
dedicated PID/mount namespace anchored by a new `sandboxd` service, isolated from
`machined` (PID 1). Fresh 1.14 clusters default this to `true`; upgraded clusters
(ours) have no document and stay non-isolated until it is added.

## Why it breaks iSCSI

Our storage is democratic-csi (`freenas-api-iscsi`) backed by TrueNAS. The node
plugin runs `iscsiadm` against the host `iscsid` using the `nsenter` host strategy
(`kubernetes/apps/kube-system/democratic-csi/app/helmrelease.yaml`):

```yaml
node:
    hostPID: true
    driver:
        extraEnv:
            - { name: ISCSIADM_HOST_STRATEGY, value: nsenter }
            - { name: ISCSIADM_HOST_PATH, value: /usr/local/sbin/iscsiadm }
        iscsiDirHostPath: /etc/iscsi
```

democratic-csi's wrapper locates `iscsid` and enters its namespaces:

```bash
iscsid_pid=$(pgrep --exact --oldest iscsid)   # fails under sandboxd
nsenter --mount=/proc/$iscsid_pid/ns/mnt --net=/proc/$iscsid_pid/ns/net -- iscsiadm "$@"
```

The Talos `iscsi-tools` extension runs `iscsid` as a **machined-managed system
service** (its own namespace, outside the container plane). With isolation on, the
CSI pod lives inside `sandboxd`'s PID namespace, so `hostPID: true` only exposes the
sandbox's PIDs — `iscsid` is invisible. `pgrep iscsid` returns nothing and the mount
fails:

```
MountVolume.MountDevice failed ... rpc error: code = Internal desc =
{"code":1,"stderr":"failed to find iscsid pid for nsenter\n"}
```

Talos documents the boundary directly: _"with workload isolation enabled … the
kubelet cannot reach the host `iscsid` across the sandbox; use a CSI driver instead."_
Their guidance assumes the CSI runs its own `iscsid` in-pod — but the standard Talos
democratic-csi recipe offloads to the **host** `iscsid`, which is exactly the
dependency the sandbox severs.

## Validation (2026-09-24)

- miirym (no iSCSI volumes attached): isolated fine, `sandboxd` healthy, node-exporter
  (hostPID) OK — the break is invisible on nodes with no iSCSI workloads.
- palarandusk (hosting `loki-0`): `loki-0` stuck `ContainerCreating` with the
  `failed to find iscsid pid for nsenter` error. Rolling back isolation and
  power-cycling restored the mount.

## Options

1. **Keep isolation off (current).** All nodes are hyper-converged and iSCSI pods can
   schedule anywhere, so this is effectively cluster-wide `workloadIsolation: false`
   until upstream catches up.
2. **Run `iscsid` in the democratic-csi node pod (experimental).** Drop the host
   nsenter strategy and run a privileged in-pod `iscsid` (kernel modules
   `iscsi_tcp`/`libiscsi` are already host-loaded; needs `writeableSysfs`). Everything
   then happens inside the sandbox, matching Talos's intended CSI model. Untested on
   1.14 — spike on a single isolated node first.
3. **Wait for upstream.** Talos 1.14.0 shipped 2026-09-03; no democratic-csi or
   siderolabs issue exists yet for this. A maintainer already noted they "didn't think
   some projects would use the internal implementation," so a fix/recipe is likely.

## Rollout procedure (for when unblocked)

Enabling requires a reboot per node (the apply stages the config; `sandboxd` and the
namespace only come up on boot). Roll one node at a time and validate before moving on.

1. Apply: `just talos apply-node <node> auto`
2. **Reboot with `talosctl -n <ip> reboot --mode powercycle`** — the default kexec
   reboot hangs before `apid` on this hardware.
3. Verify `talosctl -n <ip> services` shows `sandboxd` Running and a fresh boot.
4. Verify hostPID / host-mount workloads: node-exporter, democratic-csi node plugin,
   and — critically — that an iSCSI PVC actually mounts on the isolated node.

## References

- Talos 1.14 what's-new / `SecurityProfileConfig` (siderolabs docs)
- democratic-csi `docker/iscsiadm` wrapper (nsenter strategy)
- siderolabs/extensions `storage/iscsi-tools/iscsid.yaml` (iscsid as a system service)
- democratic-csi issues #461, #488, #485; siderolabs/extensions #38, #688
