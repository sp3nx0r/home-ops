# Thermal and Noise Tuning

> Status: In progress — software fix done, BIOS and physical changes pending
> Investigated: 2026-10-07

Fan noise from the homelab corner gets loud at times, and a constant hum is present
even at idle. This doc records what was measured, what was already fixed, and the
remaining BIOS and physical changes for the MS-A2 nodes and the HL8 NAS.

## Summary

| Source                | Symptom                            | Cause                                                       | Fix                                     |
| --------------------- | ---------------------------------- | ----------------------------------------------------------- | --------------------------------------- |
| MS-A2 nodes           | Fans surge every ~3 minutes        | `prometheus-adapter` relisting every series once per minute | **Done** (`fcc119f6`)                   |
| MS-A2 nodes           | Spikes to 94–101°C under any burst | BIOS default TjMAX (~96–100°C), fan mode unknown            | BIOS: TjMAX 78, fan mode Quiet/Auto     |
| HL8 NAS CPU           | 60–66°C at 3% load, peaks at 95°C  | Weak cooling and/or aggressive fan curve tied to CPU temp   | BIOS: Eco mode 45 W, Smart Fan 5 curves |
| HL8 NAS drives        | Constant low hum                   | 3× WD Red Pro 7200 RPM (120 Hz) resonating in a room corner | Isolation feet, move out of corner      |
| `sardior` (MS-S1 MAX) | None — idles at ~26°C              | —                                                           | None; already on latest BIOS 1.06       |

## Hardware inventory

| Host                         | Board / model               | CPU               | BIOS (current → latest)                                                    |
| ---------------------------- | --------------------------- | ----------------- | -------------------------------------------------------------------------- |
| miirym, palarandusk, aurinax | Minisforum MS-A2            | Ryzen 9 7945HX    | 1.02 → **1.03 (CPU: 7000)**, 2025-12-16                                    |
| sardior                      | Minisforum MS-S1 MAX        | Ryzen AI MAX+ 395 | 1.06 (latest)                                                              |
| themberchaud (HL8)           | Gigabyte B550I AORUS PRO AX | Ryzen 5 5500GT    | FG (2025-10-28) → **FHc**, 2026-08-18 (rev 1.4 — confirm on board sticker) |

All three MS-A2s are the 7945HX (Zen 4) variant — use the **CPU: 7000** BIOS, not the
9000-series build.

NAS drives:

| Device        | Model                 | Type                |
| ------------- | --------------------- | ------------------- |
| sda, sde, sdg | WD Red Pro WD4003FFBX | HDD, **7200 RPM**   |
| sdb, sdc      | WD Red Plus WD40EFRX  | HDD, 5400 RPM       |
| sdd, sdf      | WD Blue SATA SSDs     | Special vdev mirror |
| nvme0n1       | Kingston SNV3S500G    | Boot pool           |

## Completed: prometheus-adapter fix

The adapter ran the chart's default rules, which list every series in Prometheus
each minute. That burst pushed the hosting node from ~57°C to ~93°C every three
minutes, and the node spent 55–66% of each day above 85°C. The heat followed the pod
when it moved from palarandusk to aurinax on 2026-10-04. No HPA consumes the
custom-metrics API.

Commit `fcc119f6` set `rules.default: false`, `logLevel: 2`, and
`metricsRelistInterval: 5m`. Adapter CPU dropped from ~0.5 cores to ~0.001 cores.
With no rules, the chart also removes the `v1beta1.custom.metrics.k8s.io`
APIService. The [zeroscaler plan](zeroscaler-plan.md) should add its rule under
`rules.external`.

## MS-A2 BIOS changes

Talos cannot change these. The fans are driven by the embedded controller (no fan or
PWM sensors are exposed to Linux), and TjMAX is an SMU firmware setting with no
supported Talos path (`module.sig_enforce=1` rules out `ryzen_smu`/`ryzenadj`).

| Setting      | Path                                                       | Value                                        |
| ------------ | ---------------------------------------------------------- | -------------------------------------------- |
| TjMAX        | `Advanced > AMD CBS > SMU Common Options > TjMAX`          | `78` (default `0` = ~96–100°C)               |
| Fan mode     | `Advanced > Hardware Monitor > FAN Mode`                   | `Quiet` or `Auto`                            |
| Custom curve | `Advanced > Hardware Monitor > CPU/System/SSD Fan Setting` | `Smart Manual`, 4 temp/PWM points (optional) |

TjMAX 78 is the change that matters. Owner benchmarks show peaks dropping from ~95°C
to ~81°C at ~5% performance cost; Silent profile and 55 W/75 W PL1 limits barely
moved peak temperature.

References:
[theDXT BIOS walkthrough](https://thedxt.ca/2025/07/minisforum-ms-a2-bios-options/),
[William Lam (7945HX)](https://williamlam.com/2025/09/quick-tip-improving-thermals-on-minisforum-ms-a2.html),
[ETCwiki benchmarks](https://etcwiki.org/wiki/Minisforum_MS-A2_9955HX_temperature_fix).

### Procedure (one node at a time)

1. Optional: flash BIOS 1.03 (CPU: 7000) first — a flash resets BIOS settings.
2. `talosctl -n <ip> reboot --mode powercycle` (kexec reboots hang on this hardware).
3. Press `Del` during POST, apply the settings above, save and exit.
4. Confirm the node unlocks its TPM-bound disk and returns to `Ready`.
5. Wait for storage replicas (Garage, Volsync) to settle before the next node.

A BIOS update can change TPM PCR measurements; check disk unlock after reflashing.

### Optional OS-side follow-up

The `amd-pstate-epp` driver runs with EPP `balance_performance`. A Talos
`machine.sysfs` patch setting
`devices.system.cpu.cpu<N>.cpufreq.energy_performance_preference: balance_power` on
every core would reduce short 5 GHz boosts. This is secondary to TjMAX; apply after
the BIOS changes if peaks are still high.

## NAS (HL8) BIOS changes

TrueNAS cannot see or control the fans: `gigabyte_wmi` exposes temperatures only, and
the board's ITE fan controller is not supported by mainline Linux.

| Setting           | Path                                                            | Value                                                         |
| ----------------- | --------------------------------------------------------------- | ------------------------------------------------------------- |
| Eco mode          | `Tweaker > Advanced CPU Settings > AMD Overclocking > ECO Mode` | `45W` (if missing, set PBO to `Auto`, reboot, and it appears) |
| CPU fan curve     | `Smart Fan 5 > CPU_FAN`                                         | Low and flat up to ~60°C, gradual ramp above                  |
| Chassis fan curve | `Smart Fan 5 > SYS_FAN*`                                        | Temperature source **System** (not CPU), gentle curve         |
| Fan Stop          | `Smart Fan 5`                                                   | Only on fans that can safely stop                             |

HDDs run at 30–44°C, so the chassis fans have headroom to slow down. Pointing them
at the System sensor stops CPU spikes from revving the case fans.

Update the BIOS to FHc (via Q-Flash) **before** setting curves, since a flash resets
settings.

### Physical maintenance

- Clean dust from the CPU cooler and intake filters.
- Re-paste the CPU.
- If it's the stock cooler, replace it with a low-profile Noctua (NH-L9a-AM4 or
  NH-L12S, check HL8 clearance).

## Acoustic treatment

The steady hum is most likely the three 7200 RPM drives (120 Hz fundamental) plus
vibration carried through the chassis into the furniture and wall.

In order of effectiveness:

1. **Decouple the NAS.** The HL8 currently sits on a metal table on a hardwood floor —
   both are resonant sounding boards, so drive vibration (120 Hz) couples straight
   into the tabletop and the floor and radiates. Break the path at two points:
    - **Chassis → table:** Sorbothane hemispheres or Isolate It! isolation feet under
      the HL8 (size for ~15–20 lb loaded weight so they compress correctly — too stiff
      and they transmit vibration anyway). A 1/2"+ high-density anti-vibration pad
      (sorbothane sheet, or a dense rubber/cork sandwich) under the chassis works too
      and is cheaper. Avoid thin foam — it bottoms out and does nothing for low hum.
    - **Table → floor:** put the table legs on rubber/silicone furniture feet or a
      mat so the hardwood doesn't act as a diaphragm. A thin metal table will still
      ring; if the hum persists, a heavier/damped surface (or a slab of paver/MDF with
      a sorbothane layer on top) under the NAS adds mass that resists vibration.
    - Keep the HL8 off any shelf shared with the MS-A2s so their fan vibration doesn't
      couple in either.
2. **Move it out of the corner.** Each adjacent boundary boosts low frequencies; pull
   it 2–3 ft from both walls.
3. **Bass traps, if needed.** Thin foam panels do not absorb hum. Use porous traps
   ≥4" thick (rock wool / mineral wool), floor-to-ceiling in the corner.
4. **Mid/high-frequency panels.** ~2" panels on the side walls help with fan whine
   from the MS-A2s.

Measure after each step before buying treatment.

### Phase 2 drive selection

[`nas-storage-plan.md`](nas-storage-plan.md) lists Seagate Exos X18/X20 as candidates.
They have loud seek clatter. If noise matters, prefer WD Red Pro 20TB or Toshiba
N300/MG-series helium drives, which hum less than air-filled 4TB drives.

## Scheduled noisy periods

These are off-hours and fine as-is; expect seek noise during them.

| Task               | Schedule                               |
| ------------------ | -------------------------------------- |
| ZFS scrub (`tank`) | Sunday 00:00                           |
| SMART short test   | Sunday 04:00                           |
| SMART long test    | 1st of month, 02:00                    |
| B2 cloud syncs     | 22:45 – 05:30, staggered               |
| Snapshots          | Hourly (`tank/backups`, `k8s-exports`) |

## Verification

Port-forward Thanos (`kubectl -n o11y port-forward svc/thanos-query 29090:9090`) and
compare before/after each change.

```promql
# MS-A2 CPU temperature (Tctl)
node_hwmon_temp_celsius{chip="pci0000:00_0000:00:18_3",sensor="temp1",instance=~"192.168.5.5.*"}

# Share of time above 85°C per node, last 24h
avg_over_time((max by (instance)(node_hwmon_temp_celsius{chip="pci0000:00_0000:00:18_3",sensor="temp1"}) > bool 85)[24h:1m])

# NAS CPU and disk temperature
max(truenas_cpu_temperature_celsius)
truenas_disk_temperature_celsius
```

Baselines from 2026-10-07:

| Metric                        | Before                       | Target after changes            |
| ----------------------------- | ---------------------------- | ------------------------------- |
| MS-A2 idle Tctl               | 57–66°C                      | ≤60°C                           |
| MS-A2 7-day peak              | 94–101°C                     | ≤80°C                           |
| Hot node, time above 85°C     | 55–66% of day (adapter host) | <1%                             |
| NAS CPU, 7-day average / peak | 66°C / 95°C                  | ≤50°C / ≤75°C                   |
| NAS HDD temperature           | 30–44°C                      | ≤45°C (don't overcool-optimize) |
