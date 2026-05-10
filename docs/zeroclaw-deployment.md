# ZeroClaw Deployment Notes

## Pre-deployment Checklist

Before pushing these manifests, you must:

### 1. Encrypt the secrets with SOPS

All three `*.sops.yaml` files contain `REPLACE_ME` placeholders. Fill in real values and encrypt:

```bash
# Generate an API key for the gateway
ZEROCLAW_API_KEY=$(openssl rand -hex 32)

# Edit secret.sops.yaml with real values, then encrypt:
sops --encrypt --in-place kubernetes/apps/default/zeroclaw/app/secret.sops.yaml
sops --encrypt --in-place kubernetes/apps/default/zeroclaw/app/oidc-secret.sops.yaml
sops --encrypt --in-place kubernetes/apps/default/zeroclaw/app/volsync-secret.sops.yaml
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
   - Name: `Jarvis`
   - Callback URL: `https://jarvis.securimancy.com/oauth2/callback`
   - Logout URL: `https://jarvis.securimancy.com/logout`
3. Copy client ID into `securitypolicy.yaml` (replace `REPLACE_ME_WITH_POCKET_ID_CLIENT_ID`)
4. Copy client secret into `oidc-secret.sops.yaml`

### 4. Set Signal phone number

Put your Signal-linked phone number (e.g., `+15551234567`) into `secret.sops.yaml` as `SIGNAL_PHONE_NUMBER`.

### 5. Set Kopia/VolSync credentials

Copy the repository path and password pattern from an existing app's volsync secret (e.g., sonarr) and adjust for zeroclaw.

## Post-deployment Steps

### Link Signal account

After the pod starts:

```bash
# Get the pod name
POD=$(kubectl get pods -n default -l app.kubernetes.io/name=zeroclaw -o jsonpath='{.items[0].metadata.name}')

# Generate a link URI (displays a tsdevice:/ URI you can convert to QR)
kubectl exec -n default -c signal-cli $POD -- curl -s http://localhost:8080/v1/qrcodelink?device_name=jarvis

# Or use signal-cli directly
kubectl exec -n default -c signal-cli $POD -- signal-cli link --name jarvis
```

Scan the QR code with your Signal app: Settings > Linked Devices > Link New Device.

### Verify web dashboard

1. Open `https://jarvis.securimancy.com`
2. Authenticate via PocketID
3. Get the pairing code from container logs:
   ```bash
   kubectl logs -n default -l app.kubernetes.io/name=zeroclaw -c app | grep -i pairing
   ```
4. Enter the pairing code in the dashboard

### Test Signal

Send a message to your Signal-linked number. Jarvis should respond.

### Verify network policy

```bash
# Should succeed (Ollama)
kubectl exec -n default -c app $POD -- wget -q -O- http://ollama-proxy.default.svc.cluster.local:11435/api/tags

# Should fail (blocked by network policy)
kubectl exec -n default -c app $POD -- wget -q -O- http://searxng.default.svc.cluster.local:8080
```

Note: The distroless image has no shell or wget, so these tests require the debian variant. The CiliumNetworkPolicy itself can be verified via Hubble or Cilium CLI.
