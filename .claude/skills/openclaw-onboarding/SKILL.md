---
name: openclaw-onboarding
description: Walk a forker through cloning openclaw-azure-template, provisioning Azure resources, configuring Telegram, and reaching a healthy first OpenClaw deploy. Use when the user says they want to set this up, deploy for the first time, onboard, or asks how to start.
---

# OpenClaw Azure onboarding

**Goal:** take a forker from a fresh clone of this repo to a healthy
OpenClaw container running on Azure with a working Telegram DM, in one
guided session. You execute the commands; the user only confirms and
pastes back values you can't fetch yourself (Telegram bot token, etc.).

## Hard rules

- **Stop on first failure.** If any command exits non-zero, surface
  the error verbatim, give a one-line recovery hint, and wait for the
  user to fix it before proceeding.
- **Confirm before every Azure-modifying command.** `az group create`,
  `az acr create`, `az storage account create`, `az deployment`,
  `az container create` — all require explicit user yes before
  running. Use the `ask_user` tool with a clear summary.
- **Never invent values.** If a required field doesn't have a sensible
  default, ask the user. Don't guess.
- **Don't leak the user's secrets.** Read them via `env.sh` only;
  never echo TELEGRAM_BOT_TOKEN, AZURE_OPENAI_API_KEY, or storage keys
  back to chat output.
- **Use the SQL tool to track phase status.** Insert one todo per
  phase at the start; update to `in_progress` and `done` as you go.

---

## Phase 1 — State detection

Goal: figure out which phases are already complete so you don't redo
them.

Run, in parallel where possible:

- `test -f scripts/env.sh && echo present || echo absent`
- `test -f .last-build && cat .last-build || echo "no build"`
- `command -v az gh jq envsubst node python3 2>/dev/null` — list which
  CLIs are present.
- `az account show --query id -o tsv 2>/dev/null` — capture current
  subscription if logged in.
- `az group show --name "$RG" --query name -o tsv 2>/dev/null` — only
  if `RG` is set in the current shell.

Summarise findings to the user in 4-5 lines. Skip phases whose
artefacts already exist (e.g. if `scripts/env.sh` exists and looks
fully filled, jump to Phase 6 verify).

---

## Phase 2 — Tool prerequisites

For every CLI missing in Phase 1's check, propose the install command
(based on OS detection: `uname` → macOS uses `brew`, Linux uses `apt`
or `dnf`):

| CLI | macOS | Debian/Ubuntu |
|---|---|---|
| `az` | `brew install azure-cli` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
| `gh` | `brew install gh` | `sudo apt install gh` |
| `jq` | `brew install jq` | `sudo apt install jq` |
| `envsubst` | `brew install gettext && brew link --force gettext` | already in coreutils |
| `node` | `brew install node` | `sudo apt install nodejs` |
| `python3` | `brew install python@3` | `sudo apt install python3` |

After installs, re-verify with `command -v` for each. If any still
missing, stop and ask the user to install manually.

---

## Phase 3 — Azure foundations

Goal: have a resource group, ACR, storage account, and file share
ready for `deploy.sh`.

Order of operations:

1. **Login.** If `az account show` fails, run `az login`. Show the
   resulting account name and ask the user to confirm.
2. **Subscription.** If user has multiple, list them with
   `az account list -o table` and ask which one. Set with
   `az account set --subscription <chosen>`. Capture the GUID — this
   becomes `SUBSCRIPTION` in env.sh.
3. **Resource group.** Ask for a name (default suggestion:
   `openclaw-rg`) and region (default `eastus`). Confirm, then
   `az group create`. Capture `RG` and `LOCATION`.
4. **ACR.** Ask for a name. Validate: 5-50 lowercase alphanumeric
   chars, globally unique. Suggest `${user_handle}openclawacr`. Run
   `az acr create --sku Basic --admin-enabled true`. Capture
   `ACR_NAME`.
5. **Storage account.** Ask for a name. Validate: 3-24 lowercase
   alphanumeric. Suggest `${user_handle}openclawstg`. Run
   `az storage account create --sku Standard_LRS --kind StorageV2`.
   Capture `STORAGE_ACCOUNT`.
6. **File share.** Run `az storage share-rm create` with
   `--name openclaw-workspace --quota 100`. The share name and mount
   path use the template defaults.
7. **Container name + DNS label.** Ask. Defaults: `openclaw` for the
   container, `${user_handle}-openclaw` for the DNS label. Validate
   the DNS label is unique in the region (try
   `az resource list --query "[?name=='${DNS_LABEL}']"` then proceed
   if empty).

Save every captured value into a draft env.sh in memory; you'll
write it in Phase 6.

---

## Phase 4 — Telegram bot

Cannot be automated — Telegram has no admin API for bot creation.

Walk the user through, sequentially:

1. "Open Telegram and start a chat with `@BotFather`."
2. "Send `/newbot`. Pick a display name. Pick a username ending in
   `bot` (e.g. `myorg_openclaw_bot`)."
3. "Copy the token BotFather gives you and paste it here."
4. After receiving token: "Now send `/setprivacy` to BotFather, choose
   your bot, and tap **Disable**. Confirm when done." This is critical
   for groups — without it, the bot only sees `@mention`s.
5. "Now open `@userinfobot` and send any message. It replies with your
   numeric user ID. Paste it here." Capture `TELEGRAM_OWNER_ID`.

Save `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_ID` to the env draft.

Do **not** echo the token back to the chat after capture.

---

## Phase 5 — LLM provider + optional add-ons

### Required: Azure OpenAI / Foundry

Ask:

1. "Do you already have an Azure AI Foundry deployment with at least
   one chat model and one embedding model?"
2. If yes: ask for the resource name (e.g. `myorg-llm`). Construct
   `AOAI_BASE_URL = https://<name>.openai.azure.com/openai/v1`.
3. Ask for the API key (paste once, store, never echo). Capture
   `AZURE_OPENAI_API_KEY`.
4. If no: stop and point them at
   [https://learn.microsoft.com/azure/ai-foundry/quickstart](https://learn.microsoft.com/azure/ai-foundry/quickstart).
   Resume after they have a working deployment.

### Required: Brave Search

"Get a free API key at https://api.search.brave.com/app/keys and
paste it here." Capture `BRAVE_SEARCH_API`.

### Optional add-ons (Y/N each)

For each, ask Y/N. If Y, walk through the relevant doc; if N, leave
the env var empty.

- **NVIDIA free models** → `NVIDIA_API_KEY` from
  https://build.nvidia.com/settings/api-keys.
- **Cloudflare Tunnel** → walk through `docs/cloudflare-tunnel.md`,
  capture `CF_TUNNEL_TOKEN`.
- **Pinned gateway token** → `openssl rand -hex 24`, capture
  `GATEWAY_TOKEN`.
- **Phone Control** → walk through `docs/phone-control.md` Phase 1
  (creating the SP), capture the three `PHONE_CONTROL_*` vars.
- **Auto-schedule** → defer; user can run it after first deploy works.

---

## Phase 6 — Write env.sh and run preflight

1. Render the captured values into `scripts/env.sh` using the format
   from `scripts/env.sh.example`. Keep blank lines and comments for
   the human-friendly version.
2. Ensure `scripts/env.sh` is in `.gitignore` (it is, but verify).
3. Run `./scripts/preflight.sh`. If it fails, stop, surface the error,
   give the recovery hint, and ask the user to confirm before
   continuing.

---

## Phase 7 — Build and deploy

Sequentially, with confirmation before each:

1. `./scripts/pull-latest.sh`
2. `./scripts/build-image.sh`
3. `./scripts/deploy.sh --dry-run` first — show the user what would be
   created, then ask for confirmation.
4. `./scripts/deploy.sh` for real.

If any fails, stop and follow the recovery hint in `docs/runbook.md`'s
common-failure table.

---

## Phase 8 — Verify and summarise

1. Confirm container reaches `Running`:
   `az container show --query containers[0].instanceView.currentState.state -o tsv`.
2. Capture FQDN:
   `az container show --query ipAddress.fqdn -o tsv`.
3. Capture gateway token from the deploy output (it's already
   printed; don't re-fetch).
4. Print a summary block:

   ```
   ✅ OpenClaw is live!

   Control UI:    http://<fqdn>:18789/
   Gateway token: <token>
   Telegram bot:  https://t.me/<botusername>

   Next steps:
   • DM your bot to confirm it replies (~5s).
   • Bookmark docs/runbook.md for daily operations.
   • If you want HTTPS, see docs/cloudflare-tunnel.md.
   • If you want to save money on idle hours, see docs/auto-schedule.md.
   ```

5. If the user has Cloudflare Tunnel enabled, also include the
   tunnelled HTTPS URL.

Done.

---

## Recovery hints quick reference

| Failing command | Hint to print |
|---|---|
| `az login` | "Open the URL in a browser, sign in, paste the code shown back here." |
| `az group create` | "Group name might already exist in another subscription. Try a different name." |
| `az acr create … name not available` | "ACR names are globally unique. Pick a different one and update env.sh." |
| `pull-latest.sh` errors on import | "Try `az acr login --name $ACR_NAME` first." |
| `build-image.sh` docker errors | "Make sure Docker / Colima is running locally." |
| `deploy.sh` validation failure | "Re-check the listed env vars in scripts/env.sh; rerun." |
| Container Pending forever | "`az container show … --query containers[0].instanceView.events` — look for ImagePullBackOff or registry auth errors." |
