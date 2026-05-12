ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG BUILD_DATE=unset
LABEL org.opencontainers.image.created="${BUILD_DATE}"

USER root

# Install gosu (privilege drop) and curl (cloudflared download).
RUN apt-get update \
 && apt-get install -y --no-install-recommends gosu curl ca-certificates \
 && curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod +x /usr/local/bin/cloudflared \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# ACP harness CLIs (Topic 10).
# Phase A: Gemini CLI — used by /acp spawn gemini, e.g. for native YouTube ingestion.
# Auth tokens land in ~/.gemini/ which openclaw-init.sh symlinks to the Azure
# Files share so OAuth survives redeploys.
RUN npm install -g @google/gemini-cli@latest

# 2026.5.3+ unbundled `brave` and `memory-lancedb`. Reinstall both from
# ClawHub during build so the wrapper image ships them in
# /home/node/.openclaw/extensions/. Run as `node` because that's the user
# that owns ~/.openclaw at runtime.
# See docs/discoveries/2026-05-06-local-54-upgrade-probe.md
#
# Codex is shipped as `@openclaw/codex` (npm spec, not clawhub). It provides
# the Codex app-server harness required for openai/gpt-* embedded agent runs
# (Telegram + Web UI). Without it, every embedded turn fails with
# "Requested agent harness 'codex' is not registered".
# See docs/discoveries/2026-05-09-codex-harness-missing.md
#
# These three are baked in because SMB-mounted Azure Files cannot persist
# node_modules (no symlink support, and native modules need to match the
# Node ABI in the image).
USER node
RUN cd /app && node openclaw.mjs plugins install clawhub:@openclaw/brave-plugin \
 && cd /app && node openclaw.mjs plugins install clawhub:@openclaw/memory-lancedb \
 && cd /app && node openclaw.mjs plugins install @openclaw/codex
USER root
WORKDIR /app

COPY openclaw-init.sh /usr/local/bin/openclaw-init.sh
RUN chmod +x /usr/local/bin/openclaw-init.sh

ENTRYPOINT ["/usr/local/bin/openclaw-init.sh"]

# Re-declare CMD: setting ENTRYPOINT in a child image RESETS the parent's CMD
# to empty. Without this, openclaw-init.sh gets no args and docker-entrypoint.sh
# exits cleanly (rc=0) → container restart loop with no openclaw process.
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
