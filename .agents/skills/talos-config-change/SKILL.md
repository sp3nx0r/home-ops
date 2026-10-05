---
name: talos-config-change
description: Changes Talos machine config in home-ops (topf patches under talos/) without locking out apid or breaking etcd quorum, by proving the change offline and writing a human-run try-mode rollout with break-glass steps. Use for any edit under talos/, apiserver flags or authentication config, kubernetesTalosAPIAccess, NetworkRuleConfig or host firewall, or before shipping a privileged eBPF node agent.
---

# Talos config change

## Mission

Prove a Talos change offline, write a rollout a human can run safely, and never apply from the agent.

## Prerequisites

- Nodes (all control-plane): miirym `.50`, palarandusk `.51`, aurinax `.52`; VIP `.254`. MinisForum MS-A2, **no BMC**: HDMI + power button are the only out-of-band access.
- The talosconfig lists all three IPs as endpoints and nodes, so `talosctl -n <ip>` works from the repo without `-e`. mise sets `TALOSCONFIG` relative to the checkout, so in a git worktree symlink it from the main checkout and trust the worktree:
    ```sh
    ln -s /opt/home-ops/talos/clusterconfig/talosconfig <worktree>/talos/clusterconfig/talosconfig
    ln -s /opt/home-ops/age.key <worktree>/age.key && ln -s /opt/home-ops/kubeconfig <worktree>/kubeconfig
    mise trust <worktree>
    ```
- Recipes (`talos/mod.just`): `just talos diff` (= `topf apply --dry-run`), `render` (→ `talos/rendered/`, gitignored), `apply-node <node> <mode>`, `nodes`, `upgrade-node`, `upgrade-k8s`.
- Details: [reference.md](reference.md).

## Workflow

1. **Pick the patch location.** topf merges `talos/all/*` then `talos/<role>/*` in lexical order, so a new numbered file (`talos/all/80-foo.yaml`) needs **no `topf.yaml` change**. Put control-plane-only settings (etcd, apiserver, trustd) in `talos/control-plane/`. Prefer a new file over editing `control-plane/00-cluster.yaml`, which many branches touch. Use `.yaml.tpl` only for per-node Go templating.
2. **Baseline render, edit, render again, validate, diff.** Rendered output contains decrypted secrets:
    ```sh
    cd talos && umask 077 && d=$(mktemp -d)
    topf render --output $d/base            # before editing
    # ...edit...
    topf render --output $d/new
    for n in miirym palarandusk aurinax; do talosctl validate --mode metal --strict -c $d/new/$n.yaml; done
    diff $d/base/miirym.yaml $d/new/miirym.yaml | head -60; rg -c 'kind: <YourKind>' $d/new/*.yaml
    rm -rf $d
    ```
    Use plain `diff` + `rg -c`; a `yq ... | sort` diff of multi-doc files printed nothing.
3. **Extra offline proof where `validate` is blind.** It doesn't compile CEL or check semantics. For authn changes, run the Go harness in [reference.md](reference.md#apiserver-authentication-config). For firewall changes, map every listener first ([reference.md](reference.md#host-firewall)).
4. **Live dry-run against one node** (read-only; shows whether a reboot is needed):
    ```sh
    timeout 120 topf apply --dry-run --nodes-filter '^palarandusk$' </dev/null
    ```
    `topf` can prompt or hang: always `</dev/null` + `timeout`.
5. **Commit, then re-render and re-validate after lefthook formats the YAML.** Push and open a **draft** PR whose body contains the rollout and break-glass below. Don't apply.
6. **Rollout to write into the PR/doc (the human runs it):**
    - Pre-flight: `talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 etcd status`, `kubectl get nodes`, `just talos diff`.
    - Order: non-VIP nodes first, **VIP holder last** (`talosctl -n <ip> get addresses | rg 192.168.5.254`). Also note where Prometheus and cilium-operator run.
    - Per node:
        ```sh
        cd talos && umask 077 && just talos render
        talosctl -n <ip> apply-config -f rendered/<node>.yaml --mode try --timeout 10m
        # verify with NEW connections (existing sessions survive via conntrack): talosctl version, kubectl get nodes, app checks
        # let the try timer EXPIRE (config reverts), then make it permanent:
        just talos apply-node <node> no-reboot     # topf shows the reviewed diff again
        ```
        Soak, then move to the next node. Finish with `rm -rf talos/rendered`.
7. **Break-glass section (always include):**
    - During try: wait. The revert is a node-local timer and needs no connectivity.
    - One node unreachable: go through a peer, `talosctl -e 192.168.5.50 -n <ip> ...`.
    - apid closed from the LAN but kube-api up: the in-cluster Talos API (tuppr, `system-upgrade`, `os:admin`).
    - Physical console. A reboot does **not** undo persisted config (encrypted STATE). Last resort: reinstall one node from ISO while etcd quorum holds on the other two.
    - Any reboot: `talosctl reboot --mode powercycle` (kexec hangs on this hardware).

## Gotchas & Edge Cases

- **Don't use `just talos apply-node <node> try` for verification.** `topf apply` has no timeout flag, and Talos's default try window is 1 minute. Use `talosctl apply-config --mode try --timeout 10m` on a rendered file. (The patch header in [#558](https://github.com/sp3nx0r/home-ops/pull/558)'s `talos/all/80-firewall.yaml` says otherwise, contradicting its own plan doc.)
- **Don't make it permanent while a try is active.** The running config already matches, so topf's diff is empty and the review step is lost.
- **`KubeAuthenticationConfig.configuration` is `merge: replace`.** It drops Talos's default anonymous scoping (`/livez`, `/readyz`, `/healthz`); restate `anonymous`.
- **`kubernetesTalosAPIAccess` is two flat lists checked independently.** Every allowed namespace can mint every allowed role (today `os:admin` × `system-upgrade`). Run narrow-role workloads inside `system-upgrade` rather than adding a namespace.
- **Secrets in output.** Rendered configs and `sops -d` contain secrets. `sops -d ... | rg -v pass` still printed the NUT password. Select non-secret keys with `yq`; render with `umask 077` into `mktemp -d`.
- Network documents (NetworkRuleConfig etc.) hot-reload. Confirm "no reboot" from the dry-run, don't assume it.
- Hardcoded node `/32`s in patches must change when a node is added; say so in a one-line comment.
- Secure Boot doesn't imply kernel lockdown (it's `[none]` here); verify node facts live ([reference.md](reference.md#node-agent-preflight)).

## Output Template

```
PR: [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>) (draft, not applied)
Files: talos/<dir>/<NN-name>.yaml (+ docs/<plan>.md)
Validation: topf render ✓ · talosctl validate --mode metal --strict ✓ ×3 · diff = <N docs/node> · CEL/firewall proof <…> · dry-run: reboot <no/yes>
Rollout: <a, b, c (VIP holder last)>; try --timeout 10m; per-node checks; expire; apply-node no-reboot
Break-glass: try timer · peer -e · in-cluster API · console
Open questions: <…>
```
