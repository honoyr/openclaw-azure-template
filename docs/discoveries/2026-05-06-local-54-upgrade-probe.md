# OpenClaw 2026.5.4 local upgrade probe — GO

**Date:** 2026-05-06
**Status:** GO. Local Docker boot of `2026.5.4` succeeds with our existing config when the wrapper Dockerfile installs `@openclaw/brave-plugin` and `@openclaw/memory-lancedb` from ClawHub at build time. No config migration required, Brave + LanceDB preserved end-to-end. Azure container `${CONTAINER}` was **not** touched during this probe.

## TL;DR

- The two unbundled plugins are both available on ClawHub / npm under canonical names — confirms the path forward sketched in [`2026-05-05-openclaw-5.4-slim-missing-plugins.md`](./2026-05-05-openclaw-5.4-slim-missing-plugins.md) is real and reachable.
- One naming correction vs. the previous discovery: the LanceDB plugin is published as **`@openclaw/memory-lancedb`** (not `@openclaw/memory-lancedb-plugin`). The brave package is **`@openclaw/brave-plugin`** as previously assumed.
- Adding `openclaw plugins install clawhub:<name>` lines to our `Dockerfile` (running as the `node` user) bakes both plugins into `/home/node/.openclaw/extensions/` inside the image. Both report `Status: loaded` after gateway start.
- Booted `openclaw-local:54-plugins` against the **unmodified** `config/config.json`. Gateway started cleanly; `/healthz` → `{"ok":true,"status":"live"}`. No config rejections. `plugins.slots.memory: memory-lancedb` and `tools.web.search.provider: brave` both validated and bound.
- The previously-suspected fallback (migrate config to `tavily` + `memory-core`) is **not necessary**. We can stay on Brave Search and LanceDB-backed memory.

## Plugin availability findings

ClawHub query inside the 5.4 image (`node openclaw.mjs plugins search …`) returns both plugins as `official` channel, version pinned to gateway version (`v2026.5.4`):

```
@openclaw/brave-plugin    code-plugin | official | v2026.5.4 — OpenClaw Brave plugin
@openclaw/memory-lancedb  code-plugin | official | v2026.5.4 — OpenClaw LanceDB-backed long-term memory plugin with auto-recall/capture
```

Both are also published to npmjs.org (verified via `npm view`):
- `https://registry.npmjs.org/@openclaw/brave-plugin/-/brave-plugin-2026.5.4.tgz`
- `https://registry.npmjs.org/@openclaw/memory-lancedb/-/memory-lancedb-2026.5.4.tgz`

We use the `clawhub:` install spec rather than raw npm so the gateway records the install metadata (channel, source-linked verification, manifest id rewrite — `@openclaw/brave-plugin` → manifest id `brave`).

### What 5.4 does ship as built-in (`/app/dist/extensions/`)

Search providers: `duckduckgo`, `exa`, `firecrawl`, `google`, `perplexity`, `searxng`, `tavily`, `web-readability` — **no `brave`**.
Memory plugins: `memory-core`, `memory-wiki`, `active-memory` — **no `memory-lancedb`**.

`/app/node_modules/@openclaw` is empty in 5.4: the bundled extensions are compiled into `/app/dist/extensions/`, while user-installed plugins live under `~/.openclaw/extensions/<id>/`.

## Boot rejection on 5.4 with current config (no plugins)

Built `openclaw-local:54-test` straight from `docker/Dockerfile` with `--build-arg BASE_IMAGE=ghcr.io/openclaw/openclaw:2026.5.4`, then booted with the unmodified `config/config.json`. Reproduces the documented blocker exactly:

```
2026-05-06T06:39:59.087+00:00 [gateway] wrote stability bundle: …gateway.startup_failed.json
Gateway failed to start: Error: Invalid config at /home/node/.openclaw/openclaw.json.
tools.web.search.provider: web_search provider is not available: brave (install or enable plugin "brave", then run openclaw doctor --fix)
plugins.slots.memory: plugin not found: memory-lancedb
Run "openclaw doctor --fix" to repair, then retry.
```

(Container exits within 2s after this. Saved to `session-state/.../boot-current-config.log`.)

## Plugin-install path — works, no config change

Built variant `openclaw-local:54-plugins` with two extra build steps (run as `node` so `~/.openclaw` is writable):

```dockerfile
USER node
RUN cd /app && node openclaw.mjs plugins install clawhub:@openclaw/brave-plugin \
 && cd /app && node openclaw.mjs plugins install clawhub:@openclaw/memory-lancedb
USER root
WORKDIR /app
```

Build-time install logs:

```
Downloading plugin @openclaw/brave-plugin@2026.5.4 from ClawHub…
Plugin manifest id "brave" differs from npm package name "@openclaw/brave-plugin"; using manifest id as the config key.
Installing to /home/node/.openclaw/extensions/brave…
Installed plugin: brave

ClawHub code-plugin @openclaw/memory-lancedb@2026.5.4 channel=official verification=source-linked
Compatibility: pluginApi=>=2026.5.4 minGateway=>=2026.4.10
Installing to /home/node/.openclaw/extensions/memory-lancedb…
Installing plugin dependencies… (~7s, fetches lancedb native binding)
Exclusive slot "memory" switched from "memory-core" to "memory-lancedb".
Installed plugin: memory-lancedb
```

Note: `openclaw plugins install` rewrites `/home/node/.openclaw/openclaw.json` to record the install. This is harmless because `openclaw-init.sh` overwrites that file from `OPENCLAW_CONFIG_B64` on every container start.

Boot with **the unmodified `config/config.json`**:

```
[openclaw-init] config written from OPENCLAW_CONFIG_B64 (7135 bytes)
[gateway] loading configuration…
[gateway] resolving authentication…
[gateway] starting...
[gateway] auto-enabled plugins:
- google/gemma-4-31b-it model configured, enabled automatically.
- nvidia/mistralai/mistral-nemotron model configured, enabled automatically.
- microsoft-foundry/model-router-1 model configured, enabled automatically.
[gateway] starting HTTP server...
[gateway] ⚠️  Gateway is binding to a non-loopback address. Ensure authentication is configured before exposing to public networks.
[health-monitor] started (interval: 300s, startup-grace: 60s, channel-connect-grace: 120s)
[canvas] host mounted at http://0.0.0.0:18789/__openclaw__/canvas/
[plugins] plugins.allow is empty; discovered non-bundled plugins may auto-load: memory-lancedb (/home/node/.openclaw/extensions/memory-lancedb/dist/index.js). Set plugins.allow to explicit trusted ids.
```

`curl http://127.0.0.1:18789/healthz` → `{"ok":true,"status":"live"}`.

`openclaw plugins inspect`:
- `brave` — Status: loaded; Capabilities: `web-search: brave`; Source: `clawhub:@openclaw/brave-plugin`.
- `memory-lancedb` — Status: loaded; Source: `clawhub:@openclaw/memory-lancedb`; Artifact kind: `npm-pack`.

The `plugins.allow is empty` notice is a hardening recommendation (gate auto-load to an explicit allowlist) — non-blocking, optional follow-up.

## Recommendation: GO

Plugin-install path is clean, preserves Brave Search + LanceDB memory (no plumbing churn, no new API keys, no breakage of `auto-capture/auto-recall` against `az://openclaw-memory/lancedb`). The two-line build-time install is self-contained inside `docker/Dockerfile`.

### Concrete diffs ready to commit

**`scripts/env.sh`** — bump pin and wrapper rev:

```diff
-export WRAPPER_REV="3"
+export WRAPPER_REV="4"
…
-export UPSTREAM_PIN="2026.5.2"  # FIXME: 2026.5.3+ removed brave & memory-lancedb plugins; migrate config to tavily/google + memory-core before unpinning
+export UPSTREAM_PIN="2026.5.4"  # 5.3+ unbundled brave & memory-lancedb; docker/Dockerfile reinstalls them from ClawHub at build time
```

(Or drop `UPSTREAM_PIN` entirely once 5.4 is the GitHub-`/releases/latest` and we trust the upstream-resolution path again. Pinning to `2026.5.4` is safer for the first deploy.)

**`docker/Dockerfile`** — add the ClawHub install block:

```diff
 RUN npm install -g @google/gemini-cli@latest

+# 2026.5.3+ unbundled `brave` and `memory-lancedb`. Reinstall both from ClawHub
+# during build so the wrapper image ships them in /home/node/.openclaw/extensions/.
+# Run as `node` because that's the user that owns ~/.openclaw at runtime.
+# See docs/discoveries/2026-05-06-local-54-upgrade-probe.md
+USER node
+RUN cd /app && node openclaw.mjs plugins install clawhub:@openclaw/brave-plugin \
+ && cd /app && node openclaw.mjs plugins install clawhub:@openclaw/memory-lancedb
+USER root
+WORKDIR /app
+
 COPY openclaw-init.sh /usr/local/bin/openclaw-init.sh
```

(Trailing `WORKDIR /app` is required: without it, the parent `/app` workdir is preserved fine, but using `WORKDIR /home/node` for the install would silently break `docker-entrypoint.sh node openclaw.mjs gateway` because the cwd changes — confirmed by a failed first build during this probe.)

**`config/config.json`** — no change required.

### Verification matrix run

| Variant | Config | Result |
|---|---|---|
| 5.4 base + current Dockerfile (no plugins) | unmodified `config.json` | ❌ `plugin not found: memory-lancedb` / `provider not available: brave` (matches prior discovery) |
| 5.4 base + Dockerfile w/ ClawHub installs | unmodified `config.json` | ✅ gateway live, `/healthz` ok, both plugins `Status: loaded` |

Config-migration path (Brave→Tavily, LanceDB→memory-core) was **not exercised** because the plugin-install path works first try and preserves the desired runtime.

### Pre-deploy follow-ups

- Bump `WRAPPER_REV` to `4` (above) since `docker/Dockerfile` is changing.
- The plugin install runs as `node` during build, but `openclaw-init.sh` later runs `chown -R node:node /home/node/.openclaw` (harmless re-chown; preserves correctness).
- Consider adding `plugins.allow: ["memory-lancedb", "memory-wiki", "brave"]` to `config/config.json` to silence the auto-load notice and explicitly gate which non-bundled plugins are trusted. Optional, not a blocker.
- `lancedb` ships native bindings; the install adds ~70 MB to the image. Acceptable; the wrapper image is already large.
- Build-time ClawHub install requires outbound internet to `registry.npmjs.org` and the ClawHub manifest endpoint. ACR build (if used) needs egress; `az acr build` should already permit this.

## Artifacts

- `session-state/.../boot-current-config.log` — failure repro on 5.4 with current config, no plugins.
- `session-state/.../boot-plugins.log` — successful boot on 5.4 with plugins installed.
- `session-state/.../Dockerfile-54-candidate` — the wrapper Dockerfile that booted cleanly.
- `docker-test54/` (uncommitted, scratch) — the throwaway Dockerfile + init script copy used during the probe. Safe to delete.

## Constraints honored

- No `scripts/env.sh`, `scripts/deploy.sh`, or anything Azure-touching modified.
- No `az` calls, no ACR pushes.
- Local Docker only; container `${CONTAINER}` untouched.
- All test containers ran with `--rm` and were stopped after each probe.
