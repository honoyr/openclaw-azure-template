#!/bin/sh
set -e

log() { echo "[openclaw-init] $*"; }

# 1. Write OpenClaw config from env var
mkdir -p /home/node/.openclaw
if [ -n "$OPENCLAW_CONFIG_B64" ]; then
  echo "$OPENCLAW_CONFIG_B64" | base64 -d > /home/node/.openclaw/openclaw.json
  log "config written from OPENCLAW_CONFIG_B64 ($(wc -c < /home/node/.openclaw/openclaw.json) bytes)"
else
  log "OPENCLAW_CONFIG_B64 not set; OpenClaw will use auto-generated default config"
fi

# 2. Persist mutable state subdirs to the Azure Files mount via symlinks.
if [ -d /mnt/openclaw-workspace ]; then
  STATE_DIR=/mnt/openclaw-workspace/_state
  mkdir -p "$STATE_DIR"
  for subdir in agents identity tasks canvas telegram; do
    SRC="$STATE_DIR/$subdir"
    DST="/home/node/.openclaw/$subdir"
    mkdir -p "$SRC"
    [ -e "$DST" ] || [ -L "$DST" ] && rm -rf "$DST"
    ln -s "$SRC" "$DST"
  done
  log "state subdirs symlinked → /mnt/openclaw-workspace/_state/{agents,identity,tasks,canvas,telegram}"

  # ACP harness auth state (Topic 10). Each harness keeps OAuth tokens in its
  # own home-directory dotdir. Symlink each to the Azure Files share so logins
  # survive redeploys.
  for tool in gemini; do
    SRC="$STATE_DIR/$tool"
    DST="/home/node/.$tool"
    mkdir -p "$SRC"
    [ -e "$DST" ] || [ -L "$DST" ] && rm -rf "$DST"
    ln -s "$SRC" "$DST"
  done
  log "ACP harness state symlinked → /mnt/openclaw-workspace/_state/{gemini}"
else
  log "WARNING: /mnt/openclaw-workspace not mounted — sessions will NOT persist across container recreation"
fi

chown -R node:node /home/node/.openclaw
log "workspace mount detected at /mnt/openclaw-workspace (azure files)"

# 3. Start Cloudflare Tunnel in background (provides HTTPS for the Control UI).
# cloudflared proxies from Cloudflare's edge → localhost:18789 (openclaw gateway).
# Runs as root (outbound-only, no privileged ports needed).
if [ -n "$CF_TUNNEL_TOKEN" ]; then
  cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" &
  CF_PID=$!
  log "cloudflared tunnel started (pid $CF_PID)"
else
  log "CF_TUNNEL_TOKEN not set — HTTPS tunnel disabled, direct HTTP only"
fi

# 4. Run openclaw via the original entrypoint, dropping privileges to node.
log "launching openclaw as node user: docker-entrypoint.sh $*"
gosu node docker-entrypoint.sh "$@"
RC=$?
log "openclaw exited with code $RC — sleeping 30s before container restart so logs flush"
[ -n "${CF_PID:-}" ] && kill "$CF_PID" 2>/dev/null || true
sleep 30
exit "$RC"
