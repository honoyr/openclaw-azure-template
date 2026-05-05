# openclaw-azure-template

Azure deployment template for [OpenClaw](https://openclaw.ai). Fork this
repo, fill in `scripts/env.sh`, run three scripts, get a working agent
that talks Telegram, holds long-term memory in an Azure Files share, and
calls Azure OpenAI / Foundry as the primary LLM with NVIDIA's free
preview-tier models as fallback.

## What you get

- **Azure Container Instance** running OpenClaw, with persistent state on
  an Azure Files share (memory, OAuth tokens, wiki, agent identity).
- **Telegram channel** with DM allowlist + optional forum topics.
- **Azure OpenAI / Foundry** primary models + **NVIDIA Build** free
  fallback (Mistral Large 3, GLM 4.7, Step 3.5 Flash).
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
./scripts/deploy.sh                # create ACI; prints token + FQDN
```

For the full path with prereqs and Telegram bot setup, see
[docs/getting-started.md](docs/getting-started.md). For an AI-guided
walkthrough that runs the commands for you, open the repo in Claude
Code and ask it to *"onboard me"* — the
[`openclaw-onboarding`](.claude/skills/openclaw-onboarding/SKILL.md)
skill takes it from there.

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
