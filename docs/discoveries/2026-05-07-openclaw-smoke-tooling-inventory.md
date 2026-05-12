# OpenClaw 2026.5.6 smoke-tooling inventory (prod read-only)

**Date:** 2026-05-07
**Status:** Task 1 complete. Read-only `az container exec` against
`${CONTAINER}` (image `${ACR_NAME}.azurecr.io/openclaw:custom-2026.5.6-5`).
Production was **not** mutated; no config changes, no message sends, no ACP
spawns. Used to pin the exact JSON shapes / commands the Tier 1 smoke harness
asserts against, instead of the inferred shapes in `design.md`.

## TL;DR — corrections vs. design.md / implementation.md

| Probe | design.md inferred | **Actual on 2026.5.6** |
|---|---|---|
| #4 config validate | `.errors \| length == 0` | **`.valid == true`** (and `.path`); on success there is **no** `.errors` array |
| #6/#7 plugins inspect | `.enabled == true and .status == "loaded"` | **`.plugin.enabled == true and .plugin.status == "loaded"`** — the descriptor is nested under `.plugin`, not at top level |
| #8/#14 status --deep telegram | `.channels.telegram.connected` | **`.health.channels.telegram.connected`** — `--deep` wraps the live snapshot under `.health` |
| #9 chat HTTP endpoint | "POST to gateway chat endpoint with bearer …, likely `/api/v1/chat`" | **No external REST endpoint.** Control UI talks pure WebSocket RPC. Use **`openclaw infer model run --json --prompt … --model …`** (or `openclaw agent --json --message …`) inside the container. No bearer needed; runs over the gateway's local Unix-domain RPC. |
| #13 file upload | "upload `sentinel.txt` via gateway file endpoint" | **No clean external upload endpoint.** `message send --media …` requires a real channel; `agent --message` has no `--media` flag. Deferred — see "Open questions" below. |
| #17 ACP spawn | `POST /acp/spawn` | **`openclaw acp client …`** — also gateway-internal, not REST. |

The matrix for `--json` exit codes / shape / channels.telegram.connected key
that the harness now uses comes from this run. `implementation.md` has been
updated to match (commit-shaped, not committed).

## Environment under test

```
$ az container exec ... --exec-command "gosu node openclaw --version"
OpenClaw 2026.5.6
```

Image: `${ACR_NAME}.azurecr.io/openclaw:custom-2026.5.6-5` (matches `.last-build`).
Container `${CONTAINER}` running, gateway listening on 18789,
telegram channel attached, brave + memory-lancedb plugins loaded.

`az container exec` quoting note: only single-token commands work cleanly.
Pipes / redirects / nested quotes in the `--exec-command` value get re-parsed
by sh inside the container with confusing results. All probes in this run
were run as a single `gosu node openclaw …` token; secondary parsing was
done locally on the captured stdout (`.smoke-inventory/*.txt`, gitignored).
The captured stdout contains ANSI escape sequences and CRLF — strip them
before piping into `jq`:

```bash
sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' < raw.txt | jq …
```

## Per-command results

### `openclaw doctor --non-interactive`

- **Exit code:** 0
- **stdout:** ~80 lines of grouped advisories. Notable on our prod config:
  - "Legacy config keys detected — `messages.tts.enabled` is legacy; use
    `messages.tts.auto`. Run `openclaw doctor --fix`." (cosmetic; we don't
    `--fix` from smoke.)
  - "Doctor changes — Moved `messages.tts.enabled` → `messages.tts.auto`
    'always'." (proposed only; we run --non-interactive, no apply.)
  - "Gateway — `gateway.mode` is unset; `gateway start` will be blocked."
    (false alarm on this surface — gateway is *already* running and
    listening on :18789. This is `doctor`'s read-only static check missing
    that `gateway.mode` defaults to `"local"` once `openclaw gateway`
    process is the listener; corroborated by `gateway status --json`'s
    `.gateway.bindMode == "lan"` and `.rpc.ok == true`.)
  - "Command owner — No command owner is configured." (cosmetic.)
  - "Skills — Some skills are allowed but missing host bins (op, gh, ffmpeg,
    etc.)." (expected in container.)
  - "Plugins — Loaded: 69, Imported: 0, Disabled: 26, **Errors: 0**."
- **stderr:** none observed (CLI writes a runtime log line `[plugins]
  memory-lancedb: plugin registered (db: az://openclaw-memory/lancedb,
  lazy init)` to stdout via the doctor pre-amble, not stderr).

**Smoke contract:** `exit 0` is sufficient. Do **not** grep for `^ERROR` in
stdout (the doctor advisories use Unicode boxes, no leading "ERROR" tokens),
and the redundant runtime log lines on stdout don't carry "ERROR" either.
The implementation.md spec ("stderr free of `^ERROR`") still holds because
no stderr is written; we keep that check as a backstop.

### `openclaw config validate --json`

- **Exit code:** 0
- **stdout (full, 60 bytes):**
  ```json
  {"valid":true,"path":"/home/node/.openclaw/openclaw.json"}
  ```
- **stderr:** none
- **`--json` shape:** `{ "valid": boolean, "path": string }`. **There is no
  top-level `errors` array** on the success path. (We did not capture the
  failure shape this run; the validator is known to throw before printing
  JSON when config is invalid — confirmed in
  `2026-05-06-image-config-local-validation.md` where the failure mode was
  `Gateway failed to start: Error: Invalid config at … agents.defaults:
  Unrecognized key: "audioModel"` written to stderr, not a JSON blob.)

**Probe #4 contract update:** assert `.valid == true`. Falling back to
`(.errors // []) | length == 0` is a safe equivalent on success; we use the
former for clarity.

### `openclaw health --json`

- **Exit code:** 0
- **`--json` top-level keys:** `ok`, `ts`, `durationMs`, `eventLoop`,
  `plugins`, `channels`, `channelOrder`, `channelLabels`, `heartbeatSeconds`,
  `defaultAgentId`, `agents`, `sessions`.
- `eventLoop.degraded == true` was observed during this read (plugin doctor
  ran concurrently). Not a hard fail signal — surface, don't block.
- `plugins.loaded == ["memory-lancedb"]` — note: `health.plugins.loaded`
  reports only **memory-slot** plugins (the loaded list is from the
  gateway's runtime registry, which here is one). This is **not** a
  reliable check for "is brave loaded" — use `plugins inspect brave --json`
  for that.
- `channels.telegram.connected == true`, `.tokenStatus == "available"`,
  `.mode == "polling"` — these are the keys we'll use in T2/T3 probe #14.

### `openclaw status --json` and `openclaw status --deep --json`

- **Exit code:** 0
- **`status --json` top-level keys:** `runtimeVersion`, `heartbeat`,
  `channelSummary`, `queuedSystemEvents`, `tasks`, `taskAudit`, `sessions`,
  `os`, `update`, `updateChannel`, `updateChannelSource`, `memory`,
  `memoryPlugin`, `gateway`, `gatewayService`, `nodeService`, `agents`,
  `secretDiagnostics`.
- **`status --deep --json`** adds **`health`** and **`lastHeartbeat`** keys
  alongside the above. The live channel snapshot lives at
  **`.health.channels.telegram.*`** (same shape as `health --json`'s
  `.channels.telegram.*`).
- `channelSummary` (top level) is `[]` on this run; the populated data is
  under `.health.channels` (deep) only.

**Probe #8/#14 contract update:** assert `.health.channels.telegram.connected == true`.

### `openclaw gateway status --json`

- **Exit code:** 0
- **Top-level keys:** `logFile`, `service`, `config`, `gateway`, `port`,
  `rpc`, `extraServices`.
- Useful assertions: `.rpc.ok == true`, `.config.cli.valid == true`,
  `.port.status == "busy"` (i.e. gateway is the listener),
  `.gateway.port == 18789`.

### `openclaw plugins list --json`

- **Exit code:** 0
- **Top-level keys:** `registry`, `plugins`, `diagnostics`.
- Each `plugins[]` entry has `id`, `name`, `version`, `kind`, `enabled`,
  `status`, plus the long capability lists. brave + memory-lancedb both
  show `enabled:true, status:"loaded"`.
- The `registry.diagnostics[]` array on this run carries a single warn:
  `"persisted-registry-stale-policy"` — the persisted plugin index is
  out of date relative to current config. Cosmetic (use `plugins
  registry --refresh` to clear). **Not** a smoke fail.

### `openclaw plugins inspect <id> --json`

- **Exit code:** 0
- **Top-level keys (this is the surprise):** `workspaceDir`, `plugin`,
  `shape`, `capabilityMode`, `capabilityCount`, `capabilities`, `typedHooks`,
  `customHooks`, `tools`, `commands`, `cliCommands`, `services`,
  `gatewayDiscoveryServices`, `gatewayMethods`, `mcpServers`, `lspServers`,
  `httpRouteCount`, `bundleCapabilities`, `diagnostics`, `policy`,
  `usesLegacyBeforeAgentStart`, `compatibility`, `install`.
- The descriptor (`enabled`, `status`, `id`, `version`, `activated`,
  `activationSource`, `activationReason`) is **nested under `.plugin`**:
  ```json
  {
    "plugin": {
      "id": "brave",
      "enabled": true,
      "status": "loaded",
      "activated": true,
      "activationReason": "enabled in config",
      …
    }
  }
  ```
- Same shape for `memory-lancedb` (`.plugin.kind == "memory"`,
  `.plugin.activationReason == "selected memory slot"`).

**Probe #6/#7 contract update:** assert
`.plugin.enabled == true and .plugin.status == "loaded"`.

### `openclaw plugins doctor`

- **Exit code:** 0
- **stdout (truncated to relevant tail):**
  ```
  [plugins] memory-lancedb: plugin registered (db: az://openclaw-memory/lancedb, lazy init)
  No plugin issues detected.
  ```
- Text-only; no `--json`. Pass signature: substring `"No plugin issues
  detected."`.

### `openclaw devices list`

- **Exit code:** 0
- **stdout** — text table; Pending(1), Paired(1) on this run. The pending
  entry is a dashboard scope-upgrade request from the user's browser
  (cosmetic, not a smoke regression). Confirms the runbook pattern
  `--exec-command "gosu node openclaw devices list"` works as documented.

## HTTP surface

```
$ curl -is http://openclaw.eastus.azurecontainer.io:18789/healthz
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Cache-Control: no-store
Content-Length: 27

{"ok":true,"status":"live"}
```

```
$ curl -is http://openclaw.eastus.azurecontainer.io:18789/readyz
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Content-Length: 14

{"ready":true}
```

`/readyz` returned 200 unauthenticated on this run — `design.md`'s "bearer
for detailed body" caveat didn't bite us. We assert status 200 only and
do not parse the body.

## Bearer-authenticated chat HTTP endpoint search — **no clean REST**

Approach taken:

1. Fetched the Control UI bundle:
   `http://openclaw.eastus.azurecontainer.io:18789/assets/index-DTbgMYT2.js`
   (1.06 MB).
2. Grep for path strings (`grep -oE '"/[a-z][a-zA-Z0-9_/-]+"'`,
   ` `/[a-z][^`]+` ` template strings, `/api/v1`, `/v1/chat`, etc.).
3. The only HTTP paths under the gateway origin used by the Control UI are:
   - `/healthz`, `/readyz` (already known)
   - `/api/chat/media/outgoing/<id>` — read-only download URLs for
     agent-emitted media, not a chat-send endpoint. Pre-signed; bearer
     not required.
4. Everything else is **WebSocket RPC**:
   ```js
   new WebSocket(this.opts.url) // url is ws://<host>:18789
   ```
   The Control UI sends gateway-internal RPC frames over WS (frames
   carrying methods like `agent.run`, `tools.invoke`, etc.). The "slash
   commands" string list (`/chat`, `/help`, `/diagnostics`, `/elev`, `/exec`,
   `/export-trajectory`, `/dreams`, `/automation`, …) found in the bundle
   are agent-side slash commands typed into chat — **not** HTTP routes.

**Conclusion.** OpenClaw 2026.5.6 does not expose a REST-shaped one-shot
chat endpoint that the smoke harness can `curl -X POST` against with a
bearer token. The supported external clients are:

- Control UI (browser, WebSocket; gates on shared-secret token + device
  identity unless `gateway.controlUi.dangerouslyDisableDeviceAuth=true`).
- ACP / Tailscale-paired CLI clients (also WebSocket).
- The local `openclaw …` CLI inside the container, which uses a Unix-
  socket-style local capability transport (no token needed for
  loopback-bound CLI invocations).

**Decision for probe #9:** use the in-container CLI:

```bash
docker exec "$LOCAL_CID" gosu node openclaw infer model run --json \
  --model google/gemma-4-31b-it \
  --prompt 'Reply with exactly the token PONG-<ts>. No other text.'
```

`infer model run --json` returns a structured response with the assistant
text + the model id actually used. `--gateway` flag forces gateway routing;
default is auto-detect. We omit `--local` so the embedded gateway handles
provider routing (matches what real agent traffic does).

Alternative: `openclaw agent --json --agent main --message "…"`. Both
exercise the gateway → provider path. We prefer `infer model run` because
it lets us pin the exact model id (assertable in the response) without
caring about routing bindings; `agent` defers model choice to the agent
config and is harder to assert on.

## File-upload endpoint shape — **deferred**

What we tried:

1. `openclaw message send --help` — has `--media <path>`, but requires
   `--channel` and `--target`. Sending to a real telegram chat from smoke
   is exactly what we want to avoid (NG3 in design.md).
2. `openclaw agent --help` — has `--message`, but **no** `--media`,
   `--file`, or `--attachment` option.
3. `openclaw infer image describe --file <path>` — accepts an image file
   and uses the *image* model path; this is the inference surface for
   image-describe (validated in
   `2026-05-06-image-config-local-validation.md`). It does **not**
   exercise the chat/agent file-attachment normalizer that
   `2026-05-06-file-handling-regression.md` flagged as the actual
   regression class. Different code path.
4. `openclaw infer model run --file <path>` — present in `--help`. The
   `--file` option says "Image file (default: [])" — so this is also
   image-only on the inference surface.
5. Gateway HTTP `POST /api/chat/media/...` — the bundle only references it
   as a *download* URL (outgoing media). No upload counterpart was found
   in the bundle.

**What's still ambiguous:** the production chat-send-with-attachment path
that the file-handling regression doc identified flows through Telegram's
inbound-media normalizer **into** chat, not out. There is no documented
external "upload a file, get a media id, attach to next chat turn" REST
endpoint that we found in the bundle or CLI help.

**Decision for probe #13 in T1:** **deferred** with a TODO. Implemented
as a SKIP that explains the deferred status; tracked here. Once we add a
WebSocket-RPC client to the harness (a tiny Node helper that calls
`tools.invoke` for `media.upload` and then `agent.run` with a media-ref
content block — same shape the Control UI uses), we can wire it. That's a
larger change than Tier 1's "no new dependencies" scope, so it lands as
its own task. T1 will still cover **probe #9 (chat)** which is the most
common file-handling regression's prerequisite (chat must work at all),
and T2 will exercise file-handling end-to-end via Telegram with a staging
bot (already on the Tier 2 task list, where having a real channel is
already an accepted dependency).

Open question for the user: **do we want a small Node `tools.invoke`
client added to `scripts/lib/` to enable probe #13 in T1?** Estimated cost:
~80 lines of Node + a `package.json`. Counter-argument: keeps the deploy
repo bash-only as designed in `design.md`'s "Test runner choice" section.
Recommend addressing in a Tier 1.1 follow-up rather than blocking Tier 1
shipping.

## ACP-spawn endpoint shape — **CLI-only, no REST**

`openclaw acp` is a CLI bridge subcommand:

- `openclaw acp` (no subcommand) — runs an ACP bridge backed by the
  Gateway. Long-lived; not a one-shot probe.
- `openclaw acp client` — interactive ACP client against the local ACP
  bridge. Stdin/stdout based; not scriptable as a one-shot smoke probe
  without a wrapper.

There is no `POST /acp/spawn` HTTP endpoint. The ACP bridge speaks ACP
over a Unix socket / stdio, not HTTP.

**Decision for probe #17 in T2/T3:** use
`openclaw acp client --session <smoke-acp-<ts>> --prompt 'echo: smoke'`
inside the container with a short stdin prompt and a `with_timeout 30`.
Document the exact invocation when implementing T2 — not relevant to T1
(probe #17 is T2/T3 only).

## Implementation.md updates landed (working tree only, not committed)

- §"Probe-by-probe spec" → #4: pass signature now reads
  `exit 0 AND .valid == true` (was `.errors | length == 0`).
- §"Probe-by-probe spec" → #6/#7: jq path now `.plugin.enabled == true
  and .plugin.status == "loaded"` (was top-level `.enabled` / `.status`).
- §"Probe-by-probe spec" → #8/#14: jq path now
  `.health.channels.telegram.connected` (was `.channels.telegram.connected`).
- §"Probe-by-probe spec" → #9: REST endpoint replaced by in-container
  `openclaw infer model run --json --model … --prompt …`. Bearer / HTTP
  path removed.
- §"Probe-by-probe spec" → #13: marked **deferred for T1** with rationale
  + open question.
- §"Probe-by-probe spec" → #17: REST endpoint replaced by
  `openclaw acp client --session …` invocation pattern; T2/T3 only.

## Local artifacts (gitignored, retained for follow-up)

- `.smoke-inventory/brave.txt`, `.smoke-inventory/memlance.txt`,
  `.smoke-inventory/plist.txt`, `.smoke-inventory/statusdeep.txt`,
  `.smoke-inventory/control-ui.js` etc. — raw stdout captures from this
  run. Useful as fixtures when we want to write a mock-server unit test
  for the harness later.

## Citations

- Prior discoveries:
  [`2026-05-06-image-config-local-validation.md`](./2026-05-06-image-config-local-validation.md),
  [`2026-05-06-file-handling-regression.md`](./2026-05-06-file-handling-regression.md),
  [`2026-05-06-local-54-upgrade-probe.md`](./2026-05-06-local-54-upgrade-probe.md).
- Smoke design / impl plan:
  [`docs/wip/smoke-test-harness/design.md`](../wip/smoke-test-harness/design.md),
  [`docs/wip/smoke-test-harness/implementation.md`](../wip/smoke-test-harness/implementation.md),
  [`docs/wip/smoke-test-harness/tasks.md`](../wip/smoke-test-harness/tasks.md).
- Upstream docs referenced for command surfaces:
  https://docs.openclaw.ai/cli/{doctor,health,status,config,plugins,gateway,agent,acp}
