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
  # Symlinked subdirs (no strict-perm checks on these paths).
  for subdir in identity tasks canvas telegram cron devices flows subagents; do
    SRC="$STATE_DIR/$subdir"
    DST="/home/node/.openclaw/$subdir"
    mkdir -p "$SRC"
    [ -e "$DST" ] || [ -L "$DST" ] && rm -rf "$DST"
    ln -s "$SRC" "$DST"
  done
  log "state subdirs symlinked → /mnt/openclaw-workspace/_state/{identity,tasks,canvas,telegram,cron,devices,flows,subagents}"

  # `agents/` cannot be symlinked: OpenClaw refuses to load auth-profiles.json
  # when its parent dir is mode 777. Azure Files SMB mounts on ACI are forced
  # to 0777 and cannot be remounted with file_mode/dir_mode.
  # Workaround: materialize agents/ on the local fs at 0700, and async-sync
  # writes back to the share so OAuth refresh tokens persist across redeploys.
  AGENTS_SRC="$STATE_DIR/agents"
  AGENTS_DST="/home/node/.openclaw/agents"
  mkdir -p "$AGENTS_SRC"
  [ -e "$AGENTS_DST" ] || [ -L "$AGENTS_DST" ] && rm -rf "$AGENTS_DST"
  mkdir -p "$AGENTS_DST"
  # Initial seed: share → local. Use cp (rsync isn't installed by default).
  if [ -n "$(ls -A "$AGENTS_SRC" 2>/dev/null)" ]; then
    cp -aT "$AGENTS_SRC" "$AGENTS_DST"
    log "agents/ seeded from share ($(find "$AGENTS_DST" -type f | wc -l) files)"
  fi
  chown -R node:node "$AGENTS_DST"
  find "$AGENTS_DST" -type d -exec chmod 700 {} +
  find "$AGENTS_DST" -type f -exec chmod 600 {} +
  log "agents/ materialized locally at $AGENTS_DST (0700/0600)"

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

  # Background sync: local agents/ → share every 60s. Captures OAuth refresh
  # tokens that the Codex/OpenAI plugins rotate during normal operation.
  (
    while true; do
      sleep 60
      # cp -auT preserves perms/timestamps and only copies newer/missing files.
      # Share dir is 0777 anyway so perms there are moot; we just need bytes.
      cp -auT "$AGENTS_DST" "$AGENTS_SRC" 2>/dev/null || true
    done
  ) &
  SYNC_PID=$!
  log "agents/ writeback sync started (pid $SYNC_PID, interval 60s)"

  # Clear stale auto-failover model overrides from prior runs. When the active
  # model config changes (e.g. fallback chain reshuffled), stuck auto-overrides
  # to now-broken models cause visible "provider rejected schema or tool payload"
  # failures on next turn. Auto-overrides are recovery state by design — safe
  # to clear; "user" overrides are kept.
  SESSIONS_JSON="$AGENTS_DST/main/sessions/sessions.json"
  if [ -f "$SESSIONS_JSON" ]; then
    node -e "const fs=require('fs');const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,'utf8'));let n=0;for(const k of Object.keys(j)){if(j[k].modelOverrideSource==='auto'){delete j[k].modelOverride;delete j[k].modelOverrideSource;n=n+1;}}fs.writeFileSync(p,JSON.stringify(j,null,2));console.log('[openclaw-init] cleared',n,'stale auto modelOverrides from',Object.keys(j).length,'sessions');" "$SESSIONS_JSON" || log "WARN: failed to scrub auto modelOverrides"
  fi
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
# Performance tweaks (per `openclaw doctor`):
#   - NODE_COMPILE_CACHE: persist compiled JS between CLI invocations,
#     trimming ~1-3s off cold starts and repeated `openclaw agent` calls.
#   - OPENCLAW_NO_RESPAWN: disable the self-respawn shim, removing one fork
#     per CLI invocation.
# /var/tmp is on tmpfs in ACI so it's free + fast; the cache rebuilds on
# each container start.
mkdir -p /var/tmp/openclaw-compile-cache
chown -R node:node /var/tmp/openclaw-compile-cache
export NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
export OPENCLAW_NO_RESPAWN=1

log "launching openclaw as node user: docker-entrypoint.sh $*"
gosu node docker-entrypoint.sh "$@"
RC=$?
log "openclaw exited with code $RC — sleeping 30s before container restart so logs flush"
[ -n "${CF_PID:-}" ] && kill "$CF_PID" 2>/dev/null || true
[ -n "${SYNC_PID:-}" ] && kill "$SYNC_PID" 2>/dev/null || true
# Final agents/ sync to share so any post-last-cycle OAuth token refresh isn't lost.
if [ -d "/home/node/.openclaw/agents" ] && [ -d "/mnt/openclaw-workspace/_state/agents" ]; then
  cp -auT /home/node/.openclaw/agents /mnt/openclaw-workspace/_state/agents 2>/dev/null || true
  log "agents/ final sync to share complete"
fi
sleep 30
exit "$RC"
