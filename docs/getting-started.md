# Getting started

A single linear walkthrough from a fresh machine to a healthy OpenClaw
deploy on Azure. If you'd rather have an AI run the commands for you,
open this repo in Claude Code and the
[`openclaw-onboarding`](../.claude/skills/openclaw-onboarding/SKILL.md)
skill will take it from here.

## 1. Prerequisites

You need:

- An **Azure subscription** with permission to create resource groups,
  Container Registries, storage accounts, and Container Instances.
- A **Telegram account** to create a bot.
- A **Brave Search** account for web search (free tier is fine).
- An **Azure AI Foundry** deployment (or Azure OpenAI) with at least one
  chat model and one embedding model deployed.
- These CLIs on your machine: `az`, `gh`, `jq`, `envsubst`, `node`,
  `python3`. macOS install in one block:

  ```bash
  brew install azure-cli gh jq gettext node python@3
  brew link --force gettext   # provides envsubst
  ```

Estimated cost on Azure: about US$30–60/month if the container runs
24/7 with the recommended 2 CPU / 4 GB. The auto-schedule add-on can
cut this by more than half.

## 2. Clone and configure

```bash
gh repo clone honoyr/openclaw-azure-template my-openclaw
cd my-openclaw
cp scripts/env.sh.example scripts/env.sh
$EDITOR scripts/env.sh
```

Fill in every variable in Sections 1, 2, and the *first three* of Section
3. The optional sections can stay blank for the first deploy; you'll
add them after the initial setup works.

## 3. Azure foundations

If you don't already have the resources:

```bash
az login
az account set --subscription "$SUBSCRIPTION"

# Resource group
az group create --name "$RG" --location "$LOCATION"

# Container Registry (admin-enabled so deploy.sh can pull)
az acr create --name "$ACR_NAME" --resource-group "$RG" \
  --sku Basic --admin-enabled true

# Storage account + workspace file share
az storage account create --name "$STORAGE_ACCOUNT" --resource-group "$RG" \
  --sku Standard_LRS --kind StorageV2
key=$(az storage account keys list --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" --query "[0].value" -o tsv)
az storage share-rm create --resource-group "$RG" \
  --storage-account "$STORAGE_ACCOUNT" --name "$WORKSPACE_SHARE" --quota 100
```

Run `./scripts/preflight.sh` to confirm everything is in order.

## 4. Telegram bot

In Telegram:

1. Open `@BotFather`.
2. `/newbot` → pick a display name → pick a username (must end in `bot`).
3. Copy the API token; paste into `TELEGRAM_BOT_TOKEN` in `scripts/env.sh`.
4. `/setprivacy` → choose your bot → **Disable**. (Required so the bot
   sees all group messages without `@mention`.)
5. Open `@userinfobot` and send any message; copy your numeric user ID
   into `TELEGRAM_OWNER_ID` in `scripts/env.sh`. This becomes the DM
   allowlist.

For multi-group / forum-topic routing, see
[docs/telegram-setup.md](telegram-setup.md).

## 5. First deploy

Three scripts:

```bash
./scripts/pull-latest.sh   # imports upstream OpenClaw image to your ACR
./scripts/build-image.sh   # builds custom wrapper (cloudflared, gemini-cli)
./scripts/deploy.sh        # creates the container; prints token + FQDN
```

`deploy.sh` validates every required env var up front. If anything is
missing it tells you which ones, exits, and changes nothing.

`deploy.sh --dry-run` (or `DEPLOY_DRY_RUN=1`) renders the config and
prints what *would* be deployed, without touching Azure. Useful when
debugging env vars.

## 6. Verify

After `deploy.sh` finishes, you should see:

```
==> Done
Ip            Fqdn
------------  ---------------------------------
20.72.150.x   your-dns-label.eastus.azurecontainer.io

Gateway Token: <hex string>
```

- Open `http://<fqdn>:18789/` in a browser. Paste the token. The
  Control UI loads.
- Send a DM to your bot in Telegram. It should reply in a few seconds.

If anything misbehaves, see [docs/runbook.md](runbook.md) for log
inspection and recovery commands.

## 7. Where to go next

- **Pin the gateway token** so it survives redeploys:
  `openssl rand -hex 24` → set `GATEWAY_TOKEN` in `env.sh` → redeploy.
- **Add HTTPS** via Cloudflare Tunnel — see
  [docs/cloudflare-tunnel.md](cloudflare-tunnel.md).
- **Save money** by auto-scheduling start/stop — see
  [docs/auto-schedule.md](auto-schedule.md).
- **Control the container from your phone** — see
  [docs/phone-control.md](phone-control.md).
- **Add Telegram groups and forum topics** — see
  [docs/telegram-setup.md](telegram-setup.md).
