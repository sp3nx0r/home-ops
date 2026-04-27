# Cloudflare Tunnel Notes

## QUIC vs HTTP/2 Transport Protocol

Switched from QUIC to HTTP/2 on 2026-04-27 due to persistent tunnel connection
flapping with QUIC (`timeout: no recent network activity`, followed by reconnects).

### Symptoms with QUIC

- `failed to accept QUIC stream: timeout: no recent network activity`
- `accept stream listener encountered a failure while serving`
- All 4 tunnel connections cycling through disconnect/reconnect every few minutes
- Browser requests hanging during reconnect gaps

### Likely Causes of QUIC Flapping

- **ISP or UniFi NAT/firewall UDP session timeouts** — UDP flows get aggressively
  reaped compared to TCP, causing QUIC connections to silently die
- **MTU issues** — QUIC packets silently dropped when exceeding path MTU; PMTUD
  over UDP is less reliable than TCP
- **UniFi IDS/IPS or traffic shaping** — sustained UDP flows may be flagged or
  throttled

### What HTTP/2 Gives Up

- **No post-quantum crypto** — cloudflared only supports post-quantum with QUIC;
  theoretical risk from future quantum computers, not relevant for a homelab
- **Head-of-line blocking** — HTTP/2 multiplexes over a single TCP connection, so
  one slow request can block others (QUIC has per-stream flow control); negligible
  at homelab traffic levels
- **Slightly slower connection setup** — 2 RTT (TCP+TLS) vs 1 RTT (QUIC) or 0-RTT
  on resume; single-digit millisecond difference

### Revisiting QUIC

If the UniFi gateway firmware or ISP network changes, QUIC can be re-tested by
setting `TUNNEL_TRANSPORT_PROTOCOL: quic` and `TUNNEL_POST_QUANTUM: true` in the
helmrelease env vars. Monitor `kubectl logs` for the flapping pattern above.
