# OpenClaw 2026.5.x — codex harness missing + container debug learnings

**Date:** 2026-05-09
**Status:** Telegram fully restored. Image `${ACR_NAME}.azurecr.io/openclaw:custom-2026.5.9-beta.1-6` deployed and verified via 13/13 smoke probes (commit `0b55288`).

## TL;DR

OpenClaw 2026.5.x split the **Codex agent harness** out of the bundled
extensions into a separately-installable npm package `@openclaw/codex`. Our
wrapper image did not install it, so:

- `openai/gpt-5.5` (our default model) routes through the **codex** runtime by design,
- but the harness was **not registered**, so every embedded agent turn (Telegram + Web UI) failed silently with `Requested agent harness "codex" is not registered` → `Embedded agent failed before reply` → user sees `[assistant turn failed before producing content]` or `⚠️ Something went wrong`.
- Direct `openclaw infer model run --model openai/gpt-5.5` **worked** (different code path), which made this look like "config issue" for days.

**Fix (one line in Dockerfile):**

```dockerfile
RUN cd /app && node openclaw.mjs plugins install clawhub:@openclaw/brave-plugin \
 && cd /app && node openclaw.mjs plugins install clawhub:@openclaw/memory-lancedb \
 && cd /app && node openclaw.mjs plugins install @openclaw/codex
```

Pattern matches existing `brave` / `memory-lancedb` installs. The harness
*cannot* be persisted via the Azure Files share (SMB does not support symlinks,
and `node_modules/` is full of them) — bake into the image.

## Root-cause timeline

1. **Symptom:** Telegram silently broken across all topics. Some UI sessions
   returned `[assistant turn failed before producing content]`, others worked
   (the working ones used a different model).
2. **First wrong hypothesis:** Google fallbacks were the culprit. Removed
   `model.fallbacks=[]`, redeployed. Did not fix.
3. **Second wrong hypothesis:** Topic configs pin a missing model. Verified
   they're clean (only `systemPrompt` per topic).
4. **Real lead** (logs): `Requested agent harness "codex" is not registered.`
5. **Half-fix attempt:** Added `plugins.entries.codex={enabled:true}` and
   `plugins.entries.openai={enabled:true}` to `config.json`. Boot still failed.
6. **The smoking gun** (`openclaw plugins inspect codex --json`):
   ```
   Plugin not found: codex. Run openclaw plugins list to see installed plugins.
   ```
   And from `plugins list` warnings:
   ```
   plugins.entries.codex: plugin not installed: codex —
     install the official external plugin with:
     openclaw plugins install @openclaw/codex
   ```
7. Ran the install in-container; harness registered immediately. Confirmed via:
   `openclaw plugins inspect codex --json` → `status: loaded, activated: true`.
8. Baked into Dockerfile so it survives container recreates.

## Diagnostics that actually helped (vs. the ones that didn't)

| Tool / command | Verdict | Notes |
|---|---|---|
| `openclaw plugins inspect <id> --json` | ⭐ definitive | `Plugin not found` vs nested descriptor instantly shows install vs config issue |
| `openclaw plugins list` (head only) | ⭐ definitive | Surfaces "install with: …" warnings at the top |
| `openclaw infer model run --json --model X --prompt ping` | ⭐ useful | Bypasses harness; **passes when embedded agent fails**. Use both. |
| `az container logs --tail 200 \| grep -i harness` | ⭐ definitive | First sighting of the real error |
| `openclaw doctor` | ❌ hangs ~3min | Don't put in automation; kill + skip |
| `openclaw agent --json --message …` | partial | Reproduces the embedded-agent failure; slow |
| `ls /app/extensions/<name>/index.js` | ⚠️ misleading | Bundled extensions ship as **.ts source only**; lack of `index.js` is normal for bundled, but means an *external* plugin must be installed in `~/.openclaw/npm/`. |

## Container-debug techniques learned (keep using these)

### `az container exec` quirks

- **Single-quoted shell with `>` redirects breaks** the inline parser. **Workaround:** write the script to `/tmp/foo.sh` locally, upload via `az storage file upload … --path _state/foo.sh`, exec via `bash /mnt/openclaw-workspace/_state/foo.sh`.
- **Multi-KB outputs occasionally drop one byte** (transport flake). Smoke retries 3×.
- **Some commands hang for minutes** (`openclaw doctor`, sometimes `plugins list`). Always wrap in `timeout 30`.
- **`gosu node`** before any `openclaw …` invocation — running as root corrupts file ownership in `~/.openclaw`.

### Filesystem layout / persistence model

| Path | Lives in | Persists across container recreate? |
|---|---|---|
| `/app/extensions/<name>/` | image | ✅ (rebuild) — bundled stock plugins, source only |
| `/app/dist/extensions/<name>/index.js` | image | ✅ — compiled bundled plugins (e.g. openai) |
| `/home/node/.openclaw/extensions/<name>/` | container-local | ❌ unless baked into image |
| `/home/node/.openclaw/npm/node_modules/@openclaw/<x>/` | container-local | ❌ unless baked into image |
| `/home/node/.openclaw/agents/` | local fs (chmod 700) | ✅ via 60s rsync writeback to share |
| `/home/node/.openclaw/{identity,tasks,canvas,telegram,cron,devices,flows,subagents}` | symlink to share | ✅ |
| Anything with **symlinks inside** (e.g. `node_modules`) | — | ❌ on SMB. Must live in image. |

### Azure Files SMB constraints (forced 0777, no symlinks)

- ACI cannot pass `file_mode`/`dir_mode` mount options → share is forced to 0777.
- OpenClaw refuses to load `auth-profiles.json` if its parent dir is 0777 → `agents/` cannot be a symlink to the share. Use the materialize-then-writeback pattern from `openclaw-init.sh`.
- SMB does **not support symbolic links** → anything containing symlinks (npm `node_modules`, `.bin/` shims, peer-dep links) must live in the image, not the share.

### Logic App role-assignment wipe

Every `az container create` recreates the container's managed identity object,
which **wipes** all role assignments on it. `scripts/deploy.sh` re-creates the
3 Logic-App-side `Container Instances Contributor` assignments after each
deploy. If you ever bypass `deploy.sh`, restore them manually:

- PIDs: `fac60b15-9e54-4757-8c14-7d4693449eac` (start), `dce84b7e-9422-4e83-a880-e391008615c2` (stop), `d88f0ab2-8315-4f0e-9120-6a135c417627` (status)
- Role: `5d977122-f97e-4b4d-a52f-6b43003ddb4d`
- Scope: container resource ID

## Smoke-pipeline upgrades (commit `06a184c`)

Added during this debugging cycle so the next regression catches itself
within seconds of deploy:

| # | Probe | Catches |
|---|---|---|
| 9 | LLM primary chat — **dynamically resolves** primary from in-container `config.json` (was hard-coded to `google/gemma-…`) | Drift between deploy config and live config |
| 19 | Scan last 200 log lines (post-`gateway ready`) for **7 forbidden patterns** | `harness-not-registered`, `embedded-agent-failed`, `model-warmup-failed`, `model-catalog-load-failed`, `surface_error reason=format`, `provider-rejected-schema`, `insecure-perms-7\d\d` |
| 20 | `infer model run` against primary, fail if "harness not registered" in output | Specifically the codex-style class of harness gaps |

Also: `scripts/deploy.sh` now defaults to `SMOKE_TIER=prod`. Use `--no-smoke`
to opt out for one-off deploys.

⚠️ **Probe 20 has a blind spot:** `infer model run` does **not** exercise the
embedded-agent path. It can pass while Telegram is broken (this happened on
2026-05-08). **Probe 19 is the authoritative check** for the embedded path.
Consider adding a probe 21 that round-trips through `openclaw agent --json`
once a fast variant exists.

## Heuristics for future model/harness regressions

When a model "works directly but fails in Telegram":

1. **First**: `az container logs … --tail 300 | grep -iE "harness|embedded.agent|provider"` — almost always a one-line answer there.
2. **Then**: `openclaw plugins inspect <expected-harness> --json` and `openclaw plugins list 2>&1 | head -30`. If "Plugin not found" or "install with: …" appears, that's it.
3. **If the plugin is bundled (no install line)**: check `/app/dist/extensions/<id>/index.js` exists. Bundled plugins ship as `.ts` in `/app/extensions/` but their **compiled** form lives under `/app/dist/extensions/<id>/`. If only `.ts` exists, the upstream image is incomplete — open an issue against `openclaw/openclaw`.
4. **If the plugin is npm-distributed**: bake `node openclaw.mjs plugins install @openclaw/<id>` into the Dockerfile under the `USER node` block. Do **not** rely on share persistence — `node_modules/` symlinks will fail on SMB.
5. **Verify auth profile** matches the harness. Codex uses `openai-codex:<email>` (OAuth) or `openai:<email>` (API key). `auth-profiles.json` lives in `/home/node/.openclaw/agents/<agent>/agent/auth-profiles.json`.
6. **Always** re-run `scripts/smoke-prod.sh` after the fix; probes 19 + 20 must both pass.

## Open follow-ups

- [ ] Add a `probe 21` that round-trips a real prompt through `openclaw agent --json` (embedded path), so the harness gap doesn't depend on log-scraping.
- [ ] Investigate whether 2026.5.x will move codex back into the bundle, or if more harnesses (gemini, anthropic) will follow the same npm-split pattern. If so, generalize the Dockerfile install line into a list.
- [ ] Photo-cron warning (probe #17, `job 'photo-inbox-extract' not found`) is preexisting — separate ticket.
