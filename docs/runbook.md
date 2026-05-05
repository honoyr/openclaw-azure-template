# Runbook

> When to read this: after you've completed [getting-started.md](getting-started.md)
> and the container is running. Day-to-day operations live here.

## Daily commands

All commands assume you've sourced `scripts/env.sh`.

```bash
source scripts/env.sh
```

### Tail logs

```bash
az container logs --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" --follow
```

### Container state

```bash
az container show --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" \
  --query "{state:containers[0].instanceView.currentState.state, restarts:containers[0].instanceView.restartCount}" \
  -o table
```

### Restart in place (no redeploy)

```bash
az container restart --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER"
```

### Stop / start

```bash
az container stop  --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER"
az container start --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER"
```

Stopped containers don't bill for compute, but the storage and ACR do.

### Redeploy (config or image change)

```bash
./scripts/deploy.sh
```

This deletes and recreates the container. State on the Azure Files share
is preserved. Pin `GATEWAY_TOKEN` in `env.sh` to keep the same token
across redeploys (otherwise it rotates).

### Pull a new upstream OpenClaw release

```bash
./scripts/pull-latest.sh   # imports new tag to ACR
./scripts/build-image.sh   # rebuilds custom wrapper
./scripts/deploy.sh        # rolls forward
```

`pull-latest.sh` is idempotent — if your ACR already has the latest
upstream tag, it skips the import.

### Bump custom wrapper revision

If you change `docker/Dockerfile` or `docker/openclaw-init.sh`:

1. Increment `WRAPPER_REV` in `scripts/env.sh`.
2. Run `./scripts/build-image.sh` then `./scripts/deploy.sh`.

## Inspect the running config

```bash
az container exec --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" \
  --exec-command "gosu node cat /home/node/.openclaw/openclaw.json"
```

## Get the gateway token

```bash
az container exec --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" \
  --exec-command "gosu node node -e console.log(JSON.parse(require('fs').readFileSync('/home/node/.openclaw/openclaw.json')).gateway.auth.token)"
```

`deploy.sh` prints this automatically on success.

## Model providers

The container talks to two LLM providers:

- **Azure OpenAI / Foundry** (primary). Configure your deployments via
  the Azure portal; their IDs go into `models.providers.microsoft-foundry.models`
  in `config/config.template.json`.
- **NVIDIA Build** (fallback). Free preview-tier OpenAI-compatible
  endpoint. Auto-enabled when `NVIDIA_API_KEY` is set in `env.sh`.

NVIDIA's preview-tier model lineup changes — verify
[https://build.nvidia.com](https://build.nvidia.com) before relying on
specific IDs. Models bundled in this template at the time of writing:
Mistral Large 3 (675B), GLM 4.7, Step 3.5 Flash. Fallbacks trigger only
on rate-limit / quota errors from the primary.

## Secret rotation

For any secret in `scripts/env.sh`:

1. Update the value in `env.sh`.
2. Run `./scripts/deploy.sh`. The new value is injected as a
   `--secure-environment-variable` to the new container.

Storage account keys rotated in the Azure portal need no `env.sh`
change — `deploy.sh` fetches the active key at deploy time.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `deploy.sh` exits with "missing required env vars" | Some var is empty | Edit `scripts/env.sh` and rerun |
| Container restarts in a loop | Bad config (parse/validation error) | `az container logs` to see the error; check rendered config with `deploy.sh --dry-run` |
| Gateway URL gives 502 | Container still booting (~60s) or crashed | `az container show` for state; `az container logs` for cause |
| Telegram bot doesn't reply in DM | Token wrong or owner ID mismatch | Re-check `TELEGRAM_BOT_TOKEN`; verify `TELEGRAM_OWNER_ID` is your own ID via `@userinfobot` |
| Telegram bot doesn't reply in some forum topics | Bot is regular member, not admin | Promote bot to admin in the group with "Send Messages" + "Manage Topics" |
| Memory recall is empty | Embedding model not deployed in Foundry | Check `text-embedding-3-small-1` deployment exists, key is correct |
| `pull-latest.sh` errors on import | ACR not logged in or wrong name | `az acr login --name $ACR_NAME` |

## Tearing down

```bash
az group delete --name "$RG" --yes --no-wait
```

Removes the container, ACR, storage account, and everything else in
the resource group. Cannot be undone.
