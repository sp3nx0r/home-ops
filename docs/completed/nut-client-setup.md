# NUT Client Setup — Talos Nodes + TrueNAS (themberchaud)

> Goal: When the UPS signals low battery, themberchaud (NUT server) tells the
> three Talos nodes (NUT clients) to shut down gracefully before power is lost.

## Architecture

```
                    USB
CyberPower UPS ──────────── themberchaud (TrueNAS)
                              │  NUT server (upsd)
                              │  192.168.5.X:3493
                              │
              ┌───────────────┼───────────────┐
              │               │               │
          miirym         palarandusk       aurinax
        NUT client        NUT client      NUT client
       192.168.5.50      192.168.5.51    192.168.5.52
```

The UPS connects via USB to themberchaud. TrueNAS runs the NUT server (`upsd`)
which monitors battery status. The three Talos nodes run `nut-client` as a Talos
extension service, connecting to themberchaud over the network.

## Step 1: Configure NUT Server on TrueNAS (themberchaud)

1. Connect the UPS USB cable to themberchaud
2. In TrueNAS UI → **Services → UPS**:
   - **UPS Mode**: Master
   - **Driver**: auto (or `usbhid-ups` for CyberPower)
   - **Port**: auto
   - **UPS Name**: `ups` (or whatever you prefer — remember this for step 2)
   - **Monitor User**: `upsmon`
   - **Monitor Password**: choose a password (used by clients)
   - **Remote Monitor**: **enabled** (allows network clients)
   - **Shutdown Mode**: UPS goes on battery → low battery
3. Start the UPS service

### Verify the server is working

From themberchaud:

```bash
upsc ups@localhost
```

From your workstation (with nut-client installed):

```bash
upsc ups@<themberchaud-ip>
```

If the remote query fails, check that TrueNAS firewall allows port **3493/tcp**.

## Step 2: Configure NUT Client on Talos Nodes

The Talos NUT client extension is already installed via the schematic. It just
needs configuration.

### Option A: Via talhelper node patches (recommended)

Create a global patch at
`templates/config/talos/patches/global/nut-client.yaml.j2`:

```yaml
machine:
  extensionServices:
    - name: nut-client
      configFiles:
        - content: |
            MONITOR ups@<themberchaud-ip> 1 upsmon <password> secondary
            SHUTDOWNCMD "/sbin/poweroff"
            POLLFREQ 5
            POLLFREQALERT 2
            HOSTSYNC 15
            DEADTIME 25
            FINALDELAY 5
          mountPath: /usr/local/etc/nut/upsmon.conf
      environment:
        - UPS_NAME=ups
```

Replace:
- `<themberchaud-ip>` — themberchaud's IP on the 192.168.5.0/24 network
- `<password>` — the monitor password set in TrueNAS
- `ups` — the UPS name if you chose something different

Then run `task configure` and apply:

```bash
task configure
talosctl apply-config --talosconfig talos/clusterconfig/talosconfig \
  -n 192.168.5.50 -f talos/clusterconfig/kubernetes-miirym.yaml
talosctl apply-config --talosconfig talos/clusterconfig/talosconfig \
  -n 192.168.5.51 -f talos/clusterconfig/kubernetes-palarandusk.yaml
talosctl apply-config --talosconfig talos/clusterconfig/talosconfig \
  -n 192.168.5.52 -f talos/clusterconfig/kubernetes-aurinax.yaml
```

### Option B: One-liner per node (quick test)

```bash
talosctl apply-config --talosconfig talos/clusterconfig/talosconfig \
  -n 192.168.5.50 --config-patch '[
    {"op": "add", "path": "/machine/extensionServices", "value": [
      {"name": "nut-client",
       "configFiles": [{"content": "MONITOR ups@<themberchaud-ip> 1 upsmon <password> secondary\nSHUTDOWNCMD \"/sbin/poweroff\"\n", "mountPath": "/usr/local/etc/nut/upsmon.conf"}],
       "environment": ["UPS_NAME=ups"]}
    ]}
  ]'
```

## Step 3: Verify

Check the extension service is running on each node:

```bash
talosctl --talosconfig talos/clusterconfig/talosconfig service ext-nut-client -n 192.168.5.50
talosctl --talosconfig talos/clusterconfig/talosconfig service ext-nut-client -n 192.168.5.51
talosctl --talosconfig talos/clusterconfig/talosconfig service ext-nut-client -n 192.168.5.52
```

Should show `STATE: Running`. The "stage: booting" on the Talos console should
also change to "stage: running" once nut-client starts.

Check logs:

```bash
talosctl --talosconfig talos/clusterconfig/talosconfig logs ext-nut-client -n 192.168.5.50
```

Should show something like:

```
Communications with UPS ups@<themberchaud-ip> established
```

## Step 4: Test Failover

1. Pull the UPS power cable (simulate outage)
2. Watch NUT server logs on themberchaud — should report "on battery"
3. Wait for low battery threshold (or trigger manually: `upsmon -c fsd` on themberchaud)
4. Talos nodes should gracefully shut down
5. Restore power, nodes come back via AC Power Recovery (BIOS setting)

## upsmon.conf Reference

| Directive | Value | Purpose |
|-----------|-------|---------|
| `MONITOR` | `ups@host 1 user pass secondary` | Connect to NUT server as secondary (client) |
| `SHUTDOWNCMD` | `/sbin/poweroff` | Command to run when shutdown is triggered |
| `POLLFREQ` | `5` | Normal poll interval (seconds) |
| `POLLFREQALERT` | `2` | Poll interval when on battery |
| `HOSTSYNC` | `15` | Seconds to wait for other hosts before shutdown |
| `DEADTIME` | `25` | Seconds before declaring UPS unreachable |
| `FINALDELAY` | `5` | Seconds between "shutting down" and actual shutdown |

## Security Note

The NUT monitor password is stored in plaintext in the Talos machine config. If
you want to avoid committing it to git, consider using SOPS to encrypt the patch
file (rename it to `nut-client.sops.yaml.j2`) or use a Kubernetes secret
reference instead.
