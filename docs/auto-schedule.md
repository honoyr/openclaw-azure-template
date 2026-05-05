# Auto-schedule (Logic Apps cron)

> When to read this: you want the container to start and stop on a
> daily schedule (e.g. up 8am–6pm on weekdays) to cut Azure compute
> costs.

## What you get

Two Azure Logic Apps with system-assigned managed identities: one calls
`POST .../containerGroups/<name>/start` on a cron, the other calls
`/stop`. Roughly halves a 24/7 bill if you only use OpenClaw during
business hours.

## 1. Deploy the Logic Apps

```bash
source scripts/env.sh

az deployment group create \
  --resource-group "$RG" \
  --template-file azure/logic-apps-autoschedule.json \
  --parameters \
    location="$LOCATION" \
    startName="openclaw-autostart" \
    stopName="openclaw-autostop" \
    startUri="https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.ContainerInstance/containerGroups/$CONTAINER/start?api-version=2023-05-01" \
    stopUri="https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.ContainerInstance/containerGroups/$CONTAINER/stop?api-version=2023-05-01"
```

The default schedule in the template is **start at 09:00, stop at 18:00
Pacific Time, every day**. Edit
`azure/logic-apps-autoschedule.json` `recurrence` blocks to change.

## 2. Grant the managed identities permission to control the container

Each Logic App needs the **Azure Container Instances Contributor** role
on the container resource:

```bash
SCOPE="/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.ContainerInstance/containerGroups/$CONTAINER"

for la in openclaw-autostart openclaw-autostop; do
  PRINCIPAL_ID=$(az resource show \
    --resource-group "$RG" \
    --name "$la" \
    --resource-type "Microsoft.Logic/workflows" \
    --query "identity.principalId" -o tsv)
  az role assignment create \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Container Instances Contributor Role" \
    --scope "$SCOPE"
done
```

## 3. Verify

```bash
az logic workflow list --resource-group "$RG" -o table
```

Both apps should be **Enabled**. Trigger one manually to confirm:

Azure portal → Logic Apps → `openclaw-autostart` → Run → Run trigger →
Recurrence. Within a minute the container state goes Running.

## Customising the schedule

Edit the `recurrence` block in `azure/logic-apps-autoschedule.json`:

```json
"recurrence": {
  "frequency": "Day",
  "interval": 1,
  "timeZone": "Pacific Standard Time",
  "schedule": { "hours": [ "9" ], "minutes": [ 0 ] }
}
```

Other useful patterns:

- Weekdays only: add `"weekDays": ["Monday","Tuesday","Wednesday","Thursday","Friday"]`.
- Multiple times per day: `"hours": [9, 13, 17]`.
- Different timezone: `"timeZone": "Europe/London"`.

After editing, redeploy with the same `az deployment group create`
command from step 1.

## Disabling temporarily

```bash
az logic workflow update --resource-group "$RG" --name openclaw-autostart --state Disabled
az logic workflow update --resource-group "$RG" --name openclaw-autostop  --state Disabled
```

Switch back to `Enabled` to resume.

## Cost note

Logic Apps Consumption tier is essentially free at this volume (well
under the free monthly action quota). The savings come entirely from
not paying for ACI compute during off-hours.
