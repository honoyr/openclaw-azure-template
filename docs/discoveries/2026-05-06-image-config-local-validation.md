# Image / PDF / Audio model config — local validation on 2026.5.6

**Date:** 2026-05-06
**Status:** Partial GO. Config validates and gateway boots cleanly on `ghcr.io/openclaw/openclaw:2026.5.6` with the new `agents.defaults.imageModel` and `pdfModel` keys. The speculative `audioModel` block is **rejected** by the validator and was removed from `config/config.json`. End-to-end image-describe still fails (HTTP 400 from upstream providers) — see "End-to-end probe" below. Production container `${CONTAINER}` was **not** touched.

## TL;DR (audioModel verdict)

- **`audioModel`: REJECTED.** Strict schema. Must be removed.
  ```
  Gateway failed to start: Error: Invalid config at /home/node/.openclaw/openclaw.json.
  agents.defaults: Unrecognized key: "audioModel"
  ```
- **`imageModel`: ACCEPTED.** No validator complaint.
- **`pdfModel`: ACCEPTED.** No validator complaint.
- After removing `audioModel`, gateway reaches `[gateway] ready` with all 8 plugins loaded (browser, device-pair, file-transfer, memory-lancedb, memory-wiki, phone-control, talk-voice, telegram). `/healthz` → `{"ok":true,"status":"live"}`, `/readyz` → `{"ready":true}`. `openclaw config validate --json` → `{"valid":true}`.
- The `media.image` tool **does** register in `tools.catalog` (it didn't before, when only the text-only chat primary was declared). So the route registration goal is achieved.
- The actual image describe call **fails 400** against both `nvidia/microsoft/phi-4-multimodal-instruct` and `google/gemini-2.5-flash` because of a separate, distinct config issue (model-input declaration + OpenAI-compat transport), described below.

## Final config diff vs. pre-edit

```diff
       "model": { "primary": "google/gemma-4-31b-it", "fallbacks": [ … ] },
+      "imageModel": {
+        "primary": "nvidia/microsoft/phi-4-multimodal-instruct",
+        "fallbacks": ["google/gemini-2.5-flash"]
+      },
+      "pdfModel": {
+        "primary": "nvidia/microsoft/phi-4-multimodal-instruct",
+        "fallbacks": ["google/gemini-2.5-flash"]
+      },
       "workspace": "/mnt/openclaw-workspace"
```

(`audioModel` block was present in the user's first edit but removed after this validation. Left uncommitted in the working tree per the user's request to review the diff.)

## Boot result on 5.6 + new config (after audioModel removal)

```
[openclaw-init] config written from OPENCLAW_CONFIG_B64 (7423 bytes)
[gateway] loading configuration…
[gateway] auto-enabled plugins:
- google/gemma-4-31b-it model configured, enabled automatically.
- nvidia/mistralai/mistral-nemotron model configured, enabled automatically.
- microsoft-foundry/model-router-1 model configured, enabled automatically.
[gateway] http server listening (8 plugins: browser, device-pair, file-transfer,
  memory-lancedb, memory-wiki, phone-control, talk-voice, telegram; 21.6s)
[plugins] memory-lancedb: initialized (db: az://openclaw-memory/lancedb,
  model: text-embedding-3-small-1)
[gateway] ready
```

Verified:
- `curl http://localhost:18790/healthz` → `{"ok":true,"status":"live"}`
- `curl http://localhost:18790/readyz` → `{"ready":true}`
- `openclaw config validate --json` → `{"valid":true,"path":"/home/node/.openclaw/openclaw.json"}`
- No rejection of `imageModel` or `pdfModel`. No plugin load errors.

## Tool registration

`tools.catalog` (queried via `node openclaw.mjs gateway call --json tools.catalog`) now includes the `media` group with the `image` tool registered:

```
media -> ['image', 'image_generate', 'music_generate', 'video_generate', 'tts']
```

`image` was **not** in the catalog under the previous (text-only) config — this confirms the file-handling regression doc's hypothesis that the image route registers iff `imageModel` resolves to *something*. There is no separate `pdf` top-level tool — PDF handling is mediated by the `document-extract` extension (bundled, enabled) plus the chat attachment normalizer; it doesn't appear as a discrete tool in the catalog. So the `pdfModel` key is consumed silently by the agent loop (no overt registration symptom; we did not exercise PDF describe end-to-end this run).

Other groups present (no regressions): `fs`, `runtime`, `web`, `memory`, `sessions`, `ui`, `messaging`, `automation`, `nodes`, `agents`, `media`, `plugin:file-transfer`, `plugin:memory-lancedb`, `plugin:memory-wiki`.

## End-to-end image probe — FAIL (provider 400, not pairing)

CLI used: `openclaw infer image describe --file <jpg>` (canonical local-transport path; runs against the gateway via the local socket, no device pairing required — different from the `tools.invoke` over WebSocket that the file-regression probe ran into).

Test image: `https://picsum.photos/200/150.jpg` (5.6 KB JPG, fetched into the container at `/tmp/test.jpg`).

### Result with the user's config as-is

```
$ openclaw infer image describe --file /tmp/test.jpg --json
[media-understanding] image: failed (0/1) reason=Model does not support images
Error: Model does not support images: nvidia/microsoft/phi-4-multimodal-instruct
  (resolved nvidia/microsoft/phi-4-multimodal-instruct input: text)
```

So `imageModel.primary` *is* honored (the runtime picks `nvidia/microsoft/phi-4-multimodal-instruct` first), but the resolver rejects it before any HTTP call because the model is declared text-only. Fallback to `google/gemini-2.5-flash` errors with the same shape.

Root cause: `models.providers.{nvidia,google}.models[]` entries declare only `id` and `name` — no `input` field. The user-supplied entry overrides the bundled catalog (which declares Phi-4 Multimodal as text-only anyway, and Gemini 2.5 Flash as `["text","image"]`) and the resolver defaults missing `input` to `["text"]`.

Verified via `openclaw infer model inspect`:
```
nvidia/microsoft/phi-4-multimodal-instruct  input=["text"]
google/gemini-2.5-flash                     input=["text","image"]   ← bundled
```
But under our local override, the runtime treats both as text-only.

### Result with `input:["text","image"]` injected (hypothesis check)

In a throwaway variant config that adds `"input": ["text","image"]` to phi-4-multimodal-instruct, gemini-2.5-flash, and gemini-2.5-pro, the resolver accepts the model and actually issues the request:

```
Error: Image model failed (nvidia/microsoft/phi-4-multimodal-instruct): 400 status code (no body)
Error: Image model failed (google/gemini-2.5-flash):                    400 status code (no body)
Error: Image model failed (google/gemini-2.5-pro):                       400 status code (no body)
```

Both providers — NVIDIA's `https://integrate.api.nvidia.com/v1` and Google's `https://generativelanguage.googleapis.com/v1beta/openai` — reject the request with HTTP 400 (no body). Both are configured here as `api: "openai-completions"`. The most likely cause is that OpenClaw's image content-block payload, while valid for OpenAI proper, is **not accepted by the Google or NVIDIA OpenAI-compat endpoints** for vision input. The `openai-completions` transport appears to be text-only against these two providers.

### So this is *not* pairing-blocked, and it *is* reproducible

Different from the file-regression sub-agent's outcome: that probe was blocked by `NOT_PAIRED, DEVICE_IDENTITY_REQUIRED` on the WebSocket. The CLI `infer image describe` path bypasses that gate (it uses the local capability transport, not `tools.invoke`), so we got a clean reproduction of the upstream failure.

## Go/no-go for prod deploy

**Mixed verdict — depends on the deploy goal.**

| Goal | Verdict |
|---|---|
| Bump base to 2026.5.6 + 5.5 attachment-dedupe fix without audioModel rejection | ✅ GO. Boot is clean on 5.6 with the audioModel-removed config; this is a strict superset of the file-regression fix. |
| Restore native image analysis via the `image` tool | ❌ NO-GO. With either nvidia/phi-4-multimodal or google/gemini-2.5-flash declared via `api: "openai-completions"`, the runtime either refuses (input declared text-only) or upstream returns 400. Neither route works end-to-end. |

If deploy proceeds today, it will give us:
- Clean 5.6 boot with the new chat attachment dedupe fix already verified in the file-regression discovery.
- The `image` tool *visible* in the catalog (so agents will try to call it), but it will 400 on first use.
- Probably worse user experience than today, since today the tool isn't registered and the agent falls back to text-only handling cleanly.

**Recommendation:** hold the imageModel/pdfModel additions back until one of the following is true:

1. Add `"input": ["text", "image"]` to the relevant model entries **and** switch the image-capable model to a provider whose transport actually carries image content (candidates inside our existing config: a) re-declare the `google` provider with `api: "google-generative"` or whatever the canonical Google native API name is — needs a docs.openclaw.ai check we did not perform, or b) add an `amazon-bedrock` provider entry with an Anthropic Claude haiku/sonnet model — those declare `input: ["text","image"]` natively in the bundled catalog and use a non-OpenAI-compat transport).
2. Or, deploy 5.6 with **just** the `audioModel` removed and **drop** the imageModel/pdfModel additions for now (revert to the 5.6 file-regression fix scope only). This is the safest path.

The user's intent (route image/pdf to a multimodal model when chat primary is text-only) is sound; the provider routing fix is a separate, larger config change.

## Local artifacts

- `~/repos/openclaw-deploy/config/config.json` — `audioModel` removed, `imageModel`/`pdfModel` retained, **uncommitted** in working tree for user review.
- `openclaw-local:56-imgcfg` — wrapper image cached locally, built from `docker/Dockerfile` with `BASE_IMAGE=ghcr.io/openclaw/openclaw:2026.5.6`. Same Dockerfile as already committed; no wrapper changes needed.
- `ghcr.io/openclaw/openclaw:2026.5.6` — upstream image, cached.
- All test containers stopped and removed.

## Constraints honored

- Local Docker only. No `az` calls, no ACR pushes, no deploys.
- `${CONTAINER}` (Azure prod) untouched.
- No commits made; only `config/config.json` edited in the working tree (audioModel removal).
- Test containers used port 18790 / 18791 to avoid clashing with anything on 18789.

## Citations

- [`docs/discoveries/2026-05-06-file-handling-regression.md`](./2026-05-06-file-handling-regression.md) — recommended `imageModel`/`pdfModel` shape (this run is the validation).
- [`docs/discoveries/2026-05-06-local-54-upgrade-probe.md`](./2026-05-06-local-54-upgrade-probe.md) — local Docker test pattern (Dockerfile build args, `OPENCLAW_CONFIG_B64`, healthz check).
- OpenClaw 2026.5.6 schema for `agents.defaults`: accepts `model`, `imageModel`, `pdfModel`, `workspace`. Does **not** accept `audioModel` (validator output, this run).
