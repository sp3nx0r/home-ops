# Talos reference

## Apiserver authentication config

Lives in `KubeAuthenticationConfig` in `talos/control-plane/00-cluster.yaml`. Keep the diff limited to that document.

Read live state first (read-only):

```sh
talosctl -n 192.168.5.50 get authenticationconfigs.kubernetes.talos.dev -o yaml
talosctl -n 192.168.5.50 get staticpods kube-apiserver -o yaml | rg -n "anonymous|authentication-config"
for p in version api livez; do curl -sk https://192.168.5.254:6443/$p -o /dev/null -w "anon /$p: %{http_code}\n"; done
```

An anonymous `/version` returning 200 means anonymous auth is unscoped.

Pocket ID facts (v2.16 source): ID tokens carry `type: "id-token"`, `email_verified`, and `groups` (group names; reserved claim). ID tokens last 1h, refresh tokens 30d. Group restrictions are per OIDC client. Headlamp sends the **id_token**. Check claims with `curl -s https://id.${SECRET_DOMAIN}/.well-known/openid-configuration | jq '{issuer,claims_supported}'`.

Proven shape:

```yaml
configuration:
    anonymous:
        enabled: true
        conditions: [{ path: /livez }, { path: /readyz }, { path: /healthz }]
    jwt:
        - issuer: { url: "https://id.<domain>", audiences: ["<headlamp client id>"] }
          claimValidationRules:
              - expression: "claims.?email_verified.orValue(false) == true"
                message: email_verified must be true
              - expression: 'claims.?type.orValue("") == "id-token"'
                message: only Pocket ID ID tokens are accepted
          claimMappings:
              username: { claim: email, prefix: "oidc:" }
              groups:
                  expression: 'dyn(claims.?groups.orValue([])).filter(g, g.startsWith("k8s_")).map(g, "oidc:" + g)'
          userValidationRules:
              - expression: "!user.username.startsWith('system:')"
                message: username must not use the reserved system prefix
              - expression: "user.groups.all(g, !g.startsWith('system:'))"
                message: groups must not use the reserved system prefix
```

Offline CEL + token harness (`talosctl validate` does not compile CEL):

- Extract the rendered `configuration` (`yq 'select(.kind=="KubeAuthenticationConfig") | .configuration'`), then delete the render.
- Go module pinned to the cluster's minor (`k8s.io/apiserver@v0.37.x`). Decode into the internal `api.AuthenticationConfiguration` (`apiVersion: apiserver.config.k8s.io/v1beta1`, `install.Install(scheme)`, strict serializer).
- Run `validation.ValidateAuthenticationConfiguration(authenticationcel.NewDefaultCompiler(), cfg, nil)`.
- Build `tokenoidc.New(...)` with an `oidc.StaticKeySet` and sign RS256 test JWTs (go-jose v4, fresh RSA key).
- Cases: valid token → `oidc:k8s_admins` only; `email_verified` false/absent; `type` missing or `access-token`; no `groups`; smuggled `system:masters`; no email (client_credentials); wrong `aud`. Run against the `origin/main` config too as a baseline.

Gotchas:

- `claims.?groups.orValue([])` is type `any` and can't be iterated; wrap it in `dyn(...)`. Only the harness caught this.
- `claim`/`prefix` and `expression` are mutually exclusive in a mapping; the expression adds the prefix itself.
- `username.claim: email` adds an implicit `email_verified` check that passes when the claim is absent; keep the explicit rule.
- Rotating Pocket ID keys isn't an instant cutoff (the apiserver caches the JWKS). To revoke now, delete the OIDC bindings with the cert kubeconfig.
- Email is mutable in Pocket ID; bind groups, never individual `oidc:<email>` users.
- Check the audit log for anonymous callers before scoping (here only `kube-probe` uses `/readyz`, `/livez`).

## Talos API from pods

- `machine.features.kubernetesTalosAPIAccess` in `talos/control-plane/00-cluster.yaml`: `allowedRoles: [os:admin]`, `allowedKubernetesNamespaces: [system-upgrade]`. Checked independently, so adding a namespace hands it `os:admin`.
- Default: run the workload in `system-upgrade` and add only the narrow role (e.g. `os:etcd:backup`) to `allowedRoles`. Expect a one-line diff per CP node, no reboot.
- CR (`talos.dev/v1alpha1` `ServiceAccount`, `spec.roles: [os:etcd:backup]`). Talos mints a Secret of the same name (key `config`); mount it at `/var/run/secrets/talos.dev`. Don't dump it; inspect `endpoints`/`nodes` with `yq` only.
- Scratch images (talos-backup, talosctl): set `TALOSCONFIG=/var/run/secrets/talos.dev/config` **and** `HOME=/tmp` (`os.UserHomeDir()` fails without it). `automountServiceAccountToken: false`, read-only root, `/tmp` emptyDir sized for the snapshot plus compressed and encrypted copies.
- CNP egress (copy from `system-upgrade/tuppr`): kube-dns with the L7 DNS rule; `toEntities: [host, remote-node]` and node `/32`s + VIP on `50000`; the upload target via `toFQDNs` + `ndots: 1`.
- Sanity (read-only): `talosctl -n <ips> etcd status` (DB size), `talosctl -n <ip> get etcdspec -o yaml | rg image`, `talosctl get machinetype` (must be `controlplane`).

etcd restore traps (see [#561](https://github.com/sp3nx0r/home-ops/pull/561) for the backup design):

- Restore ≠ bootstrap. `just bootstrap talos` bootstraps an **empty** etcd. Recovery: `just talos apply`, wait for etcd `Preparing` on all nodes, then `talosctl -n <one-cp> bootstrap --recover-from=./db.snapshot`.
- A snapshot is useless without the original `talos/secrets.sops.yaml` (etcd secretbox key).
- After total NAS loss, restored PV bindings point at missing zvols. Rebuild from Git + Volsync instead.
- Run full-restore drills egress-blocked; a restored cluster drives Cloudflare DNS and writes to the prod Kopia repo.
- talos-backup's Go age accepts X25519 (and hybrid PQ) recipients, **not** plugin recipients (age-plugin-yubikey).

## Node-agent preflight

For privileged eBPF/hostPath agents (Kubescape node-agent, Tetragon). Read-only, run per node because versions drift mid-upgrade:

```sh
T="talosctl -n 192.168.5.50"
$T ls /sys/kernel/btf | rg -c vmlinux
$T read /proc/config.gz | gunzip | rg 'CONFIG_(BPF_SYSCALL|DEBUG_INFO_BTF|BPF_LSM|BPF_EVENTS|KPROBES|FTRACE|TRACEPOINTS|IKHEADERS)[=_]'
for f in /sys/kernel/security/lockdown /sys/kernel/security/lsm /sys/fs/selinux/enforce /proc/sys/kernel/unprivileged_bpf_disabled; do echo "$f: $($T read $f)"; done
for p in /boot /lib/modules /sys/fs/bpf /sys/kernel/debug /sys/kernel/tracing /var/lib/kubelet /run/containerd/containerd.sock; do printf '%s: ' $p; $T ls -l $p 2>&1 | sed -n 2p | cut -c1-100; done
```

Known facts (re-verify): lockdown `[none]` despite Secure Boot; SELinux permissive (`spc_t` harmless); no AppArmor; `module.sig_enforce=1` (module-loading agents fail; pure eBPF is fine); only bpffs, debugfs and `/run` are writable; containerd socket at the default path. A hostPath with no `type` won't be created on the read-only host. Any hostPID/hostPath/SYS_ADMIN agent needs a `privileged` PSA namespace (update AGENTS.md).

## Host firewall

Default-block ingress, live. Rules: `talos/{all,control-plane}/80-firewall.yaml`; design/ports: `docs/completed/talos-host-firewall-plan.md`. New host sockets (hostNetwork, node-IP scrapes) need a rule or are silently dropped. NodePorts/hostPorts bypass it (Cilium eBPF); see Kyverno `require-lb-no-nodeports`. Roll out per node with `--mode try --timeout 10m`, VIP holder last.

Map real host sockets first:

```sh
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 netstat -l -p | \
  awk 'NR>1 && $5 !~ /^(127\.|169\.254)/ {sub(/^[0-9]+\//,"",$NF); print $2,$5,$NF}' | \
  sed -E 's/192\.168\.5\.5[0-2]/NODEIP/' | sort | uniq -c
```

The local address is column 5. Map unknown PIDs with `talosctl -n <ip> read /proc/<pid>/cmdline | tr '\0' '\n'`.

- What the Talos firewall filters: host sockets on node IPs/VIP (apid 50000, trustd 50001, kubelet 10250, etcd 2379-2380, cilium-health 4240, metrics ports, `healthCheckNodePort`). LB IPs, NodePorts and non-hostNetwork hostPorts are eBPF and bypass it; see `cilium-cnp-authoring` [reference.md](../cilium-cnp-authoring/reference.md).
- Pod→node traffic is not SNATed, so scrapes arrive from `10.42.0.0/16`.
- Talos v1.14 also has a `prerouting` chain that drops new connections to its own addresses (including the VIP) on unallowed ports.
- Cilium's DNS proxy uses TPROXY, so proxied DNS traverses `input`. That's fine while DNS rules target kube-dns pods.
- ARP/L2 announcements aren't IP; the firewall doesn't touch them.
- NFS is v4.2 everywhere (`talosctl read /proc/self/mountinfo`), so rpcbind 111 can be blocked; re-check if NFSv3 appears.
- Talos doesn't log drops; broken flows are the only signal. Its ICMP limit of 5 pps can make cilium-health flap.
