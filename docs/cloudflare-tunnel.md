# Cloudflare Tunnel (HTTPS access)

> When to read this: you want HTTPS access to the Control UI on a
> friendly hostname (e.g. `openclaw.example.com`) instead of the raw
> `http://<fqdn>:18789/`.

## What you get

Without the tunnel: `http://<your-dns-label>.<region>.azurecontainer.io:18789/`
(plain HTTP, browsers warn, mobile push notifications often blocked).

With the tunnel: `https://openclaw.example.com/` (your domain, valid
TLS, mobile-friendly, no port). The container connects out to
Cloudflare via `cloudflared`, so you don't open any inbound ports.

## 1. Create the tunnel in Cloudflare

1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com/) →
   Networks → Tunnels → Create a tunnel → **Cloudflared** → name it
   (e.g. `openclaw`).
2. On the "Install and run a connector" screen, copy the token from the
   **install command** (the long string after `--token`).
3. Click "Next" and add a public hostname:
   - Subdomain + domain: e.g. `openclaw` + `example.com`
   - Service: **HTTP** + `localhost:18789`
4. Save.

## 2. Set the token in env.sh

```bash
export CF_TUNNEL_TOKEN="<the long string from step 1.2>"
```

## 3. Redeploy

```bash
./scripts/deploy.sh
```

The container's `openclaw-init.sh` detects `CF_TUNNEL_TOKEN` and starts
`cloudflared tunnel run --token "$CF_TUNNEL_TOKEN"` alongside OpenClaw.

## 4. Verify

In Cloudflare dashboard, the tunnel shows **Healthy** within ~30 seconds.
Open `https://openclaw.example.com/` and the Control UI loads.

## Rotating the token

Cloudflare → Tunnels → click yours → **Refresh token**. Update
`CF_TUNNEL_TOKEN` in `scripts/env.sh`. Redeploy.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Tunnel shows "Down" in Cloudflare | `az container logs` — look for `cloudflared` errors |
| `cloudflared: command not found` in logs | Custom image rebuild needed — `./scripts/build-image.sh` |
| HTTPS works but websocket disconnects | Cloudflare → tunnel → public hostname → Additional application settings → enable **HTTP/2** |
| 502 Bad Gateway | Container not yet booted; wait 60s or check `az container show` state |
