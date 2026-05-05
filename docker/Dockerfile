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

COPY openclaw-init.sh /usr/local/bin/openclaw-init.sh
RUN chmod +x /usr/local/bin/openclaw-init.sh

ENTRYPOINT ["/usr/local/bin/openclaw-init.sh"]

# Re-declare CMD: setting ENTRYPOINT in a child image RESETS the parent's CMD
# to empty. Without this, openclaw-init.sh gets no args and docker-entrypoint.sh
# exits cleanly (rc=0) → container restart loop with no openclaw process.
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
