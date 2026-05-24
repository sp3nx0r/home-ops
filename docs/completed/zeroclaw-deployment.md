# ZeroClaw Deployment Notes

## Pre-deployment Checklist

Before pushing these manifests, you must:

### 1. Encrypt the secrets with SOPS

All `*.sops.yaml` files contain `REPLACE_ME` placeholders. Fill in real values and encrypt:

```bash
# Generate an API key for the gateway
ZEROCLAW_API_KEY=$(openssl rand -hex 32)

# Edit secret files with real values, then encrypt:
sops --encrypt --in-place kubernetes/apps/zeroclaw/zeroclaw/app/secret.sops.yaml
sops --encrypt --in-place kubernetes/apps/zeroclaw/zeroclaw/app/oidc-secret.sops.yaml
sops --encrypt --in-place kubernetes/apps/zeroclaw/zeroclaw/app/volsync-secret.sops.yaml
sops --encrypt --in-place kubernetes/apps/zeroclaw/zeroclaw/app/persona-secret.sops.yaml
```

### 2. Create a Discord bot

1. Go to https://discord.com/developers/applications
2. Create a new application, add a Bot
3. Enable "Message Content Intent" under Privileged Gateway Intents
4. Copy the bot token into `secret.sops.yaml` as `DISCORD_BOT_TOKEN`
5. Invite the bot to your private server
6. Get your Discord user ID (Developer Mode > right-click > Copy ID)
7. Set as `DISCORD_ALLOWED_USERS` in the secret

### 3. Register PocketID OIDC client

1. Open PocketID admin UI (`https://id.securimancy.com`)
2. Create OIDC client:
   - Name: `ZeroClaw`
   - Callback URL: `https://zeroclaw.securimancy.com/oauth2/callback`
   - Logout URL: `https://zeroclaw.securimancy.com/logout`
3. Copy client ID into `securitypolicy.yaml`
4. Copy client secret into `oidc-secret.sops.yaml`

### 4. Set Signal phone number

Put the Signal phone number (e.g., `+14795518443`) into `secret.sops.yaml` as
`SIGNAL_PHONE_NUMBER`. This number will be registered as a primary Signal device
via SMS verification (not linked to an existing device).

### 5. Set Kopia/VolSync credentials

Copy the repository path and password pattern from an existing app's volsync
secret (e.g., sonarr) and adjust for zeroclaw.

## Post-deployment Steps

### Register Signal account (SMS flow)

The signal-cli sidecar registers as a **primary device** via SMS — not QR code
linking. This is required for numbers that can't scan QR codes (e.g., Google Voice).

```bash
# 1. Generate a captcha token
#    Open https://signalcaptchas.org/registration/generate.html in a browser
#    Complete the hCaptcha, copy the signalcaptcha://... URI

# 2. Strip the signalcaptcha:// prefix and POST to register
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s --max-time 120 -X POST \
  http://localhost:8080/v1/register/+14795518443 \
  -H 'Content-Type: application/json' \
  -d '{"use_voice": false, "captcha": "signal-hcaptcha.5fad97ac-..."}'

# 3. Check SMS on the phone number, then verify
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s -X POST http://localhost:8080/v1/register/+14795518443/verify/<CODE> \
  -H 'Content-Type: application/json' -d '{}'

# 4. Set profile name
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s -X PUT http://localhost:8080/v1/profiles/+14795518443 \
  -H 'Content-Type: application/json' \
  -d '{"name": "Wintermute"}'

# 5. Verify account is registered
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s http://localhost:8080/v1/accounts
# Should return ["+14795518443"]
```

> **Note**: Captcha tokens are single-use. If the first request times out (common),
> the token is consumed. Generate a fresh captcha and retry. The verification code
> SMS may land in spam on Google Voice.

> **Note**: If verify returns "Account is already registered", the newer Signal
> protocol may have auto-verified during registration. Check `/v1/accounts` — if
> the number appears, registration succeeded. A supervisord restart
> (`supervisorctl restart all`) may be needed for the REST API to recognize the
> new account.

### Configure Signal channel in ZeroClaw

The Signal channel config lives in `config.toml` on the PVC:

```toml
[channels.signal]
account = "+14795518443"
allowed_from = ["+18323709367"]
enabled = true
http_url = "http://localhost:6002"
```

ZeroClaw connects to signal-cli's native HTTP endpoint (port 6002) for SSE message
streaming. See `kubernetes/apps/zeroclaw/README.md` for details on the dual
TCP+HTTP signal-cli architecture.

### Verify web dashboard

1. Open `https://zeroclaw.securimancy.com`
2. Authenticate via PocketID
3. Gateway pairing is **disabled** — OIDC SecurityPolicy handles auth

### Test Signal

Send a message from the allowed number (+18323709367) to +14795518443. ZeroClaw
should respond via Wintermute.

### Verify network policy

```bash
# Test ollama connectivity from inside the pod
kubectl -n zeroclaw exec deploy/zeroclaw -c app -- \
  curl -s -o /dev/null -w '%{http_code}' \
  http://ollama-proxy.default.svc.cluster.local:11435/v1/models

# Test SearXNG connectivity
kubectl -n zeroclaw exec deploy/zeroclaw -c app -- \
  curl -s -o /dev/null -w '%{http_code}' \
  http://searxng.default.svc.cluster.local:8080
```

> **Note**: These tests require the `-debian` image variant. The distroless image
> has no shell or curl.
