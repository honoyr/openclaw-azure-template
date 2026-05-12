# openclaw-azure-template

Azure deployment template for [OpenClaw](https://openclaw.ai). Fork this
repo, fill in `scripts/env.sh`, run three scripts, get a working agent
that talks Telegram, holds long-term memory in an Azure Files share, and
runs `openai/gpt-5.5` via the Codex app-server harness as the primary LLM
(Azure OpenAI / Foundry / NVIDIA still available as opt-in fallbacks).

## What you get

- **Azure Container Instance** running OpenClaw, with persistent state on
  an Azure Files share (memory, OAuth tokens, wiki, agent identity).
- **Telegram channel** with DM allowlist + optional forum topics.
- **`openai/gpt-5.5` primary** via Codex app-server harness (baked into
  the image, no model-routing surprises). Azure OpenAI / Foundry / NVIDIA
  available as opt-in fallbacks via config.
- **Always-on smoke health checks** that run after every deploy. 20 probes
  codify every regression debugged in production (codex harness missing,
  perms 777, model warmup, surface_error format, telegram counts,
  cloudflare tunnel, photo-cron, etc.).
- **Optional add-ons**: Cloudflare Tunnel for HTTPS, iOS Phone Control
  shortcuts, Logic Apps auto-schedule (start/stop on a cron), Brave web
  search, Gemini CLI for ACP agents.

## Quick Start

```bash
gh repo clone honoyr/openclaw-azure-template my-openclaw
cd my-openclaw
cp scripts/env.sh.example scripts/env.sh
$EDITOR scripts/env.sh             # ~13 required vars (see table below)
./scripts/preflight.sh             # verify Azure access + tools
./scripts/pull-latest.sh           # import upstream image to your ACR
./scripts/build-image.sh           # build custom wrapper image
./scripts/deploy.sh                # create ACI; runs smoke; prints token + FQDN
```

For the full path with prereqs and Telegram bot setup, see
[docs/getting-started.md](docs/getting-started.md). For an AI-guided
walkthrough that runs the commands for you, open the repo in Claude
Code and ask it to *"onboard me"* — the
[`openclaw-onboarding`](.claude/skills/openclaw-onboarding/SKILL.md)
skill takes it from there.

## Health checks (smoke harness)

`scripts/deploy.sh` runs `scripts/smoke-prod.sh` automatically after every
deploy (pass `--no-smoke` to skip). The harness is a 20-probe TAP-style
script that verifies:

- container alive, `/healthz` + `/readyz` responsive
- config validates, `openclaw doctor --non-interactive` passes
- `brave`, `memory-lancedb` plugins loaded
- Telegram channel connected and counts (allow, groups, topics) match config
- primary LLM (e.g. `openai/gpt-5.5`) answers a `ping`
- Cloudflare tunnel `/healthz` (when `CF_TUNNEL_TOKEN` is set)
- photo-inbox cron registered (when enabled)
- **No forbidden patterns** in the last 200 log lines after `gateway ready`:
  `harness-not-registered`, `embedded-agent-failed`, `model-warmup-failed`,
  `model-catalog-load-failed`, `surface_error reason=format`,
  `provider-rejected-schema`, `insecure-perms-7\d\d`
- Agent harness is bound to the primary model (not just the model loaded)

There's also a faster local-Docker smoke (`scripts/smoke-local.sh`) for
pre-deploy validation, and a nightly drift workflow
(`.github/workflows/smoke-prod-nightly.yml`) that catches upstream-image
regressions.

See [docs/discoveries/](docs/discoveries/) for post-mortems explaining
why each probe exists.

## Environment variables

| Section | Vars | Required |
|---|---|---|
| Azure identity | `SUBSCRIPTION`, `RG`, `LOCATION` | Yes |
| Naming | `ACR_NAME`, `WRAPPER_REV`, `CONTAINER`, `DNS_LABEL`, `STORAGE_ACCOUNT`, `WORKSPACE_SHARE`, `WORKSPACE_MOUNT` | Yes |
| LLM | `AZURE_OPENAI_API_KEY`, `AOAI_BASE_URL`, `AOAI_RESOURCE_NAME` | Yes |
| LLM | `NVIDIA_API_KEY`, `GEMINI_API_KEY` | No |
| Channels | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_OWNER_ID`, `BRAVE_SEARCH_API` | Yes |
| Tunnel | `CF_TUNNEL_TOKEN` | No |
| Pin | `GATEWAY_TOKEN` | No |
| Phone Control | `PHONE_CONTROL_*` | No |

`scripts/env.sh.example` documents every variable with where to source
the value and which feature it enables.

## Documentation

- [docs/getting-started.md](docs/getting-started.md) — single linear
  walkthrough from clone to first deploy.
- [docs/runbook.md](docs/runbook.md) — daily operations, log inspection,
  redeploy, secret rotation.
- [docs/telegram-setup.md](docs/telegram-setup.md) — BotFather walkthrough,
  group + forum topic routing, mention/allowlist policies.
- [docs/phone-control.md](docs/phone-control.md) — iOS Shortcuts to
  start/stop/check the container via the Azure REST API.
- [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) — HTTPS access
  via cloudflared instead of the raw IP.
- [docs/auto-schedule.md](docs/auto-schedule.md) — Logic Apps cron to
  start/stop the container on a schedule (saves money when idle).

## Status & roadmap

v1 is **Azure ACI only**. GCP and AWS variants will live in sibling
repos (`openclaw-gcp-template`, `openclaw-aws-template`) as separate
adapters that share the same config + Telegram conventions.

## Licence

[MIT](LICENSE)
