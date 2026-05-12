# Discoveries

Post-mortems and debugging playbooks for issues hit during real production
use of this template. Read these before duplicating multi-day debugging
sessions of your own.

Each doc follows a consistent format: TL;DR, root cause, timeline,
diagnostics that worked vs. didn't, and (where applicable) heuristics
for similar future regressions.

## Index

| Date | Topic | When to read |
|---|---|---|
| 2026-05-05 | [OpenClaw 5.4 slim image — missing plugins](./2026-05-05-openclaw-5.4-slim-missing-plugins.md) | After upgrading to a new openclaw `*-slim` base image and containers crash in 8–10s with empty logs |
| 2026-05-06 | [Image + config local validation workflow](./2026-05-06-image-config-local-validation.md) | When you want to test a config change against a fresh openclaw image without touching prod |
| 2026-05-06 | [Local 5.4 upgrade probe](./2026-05-06-local-54-upgrade-probe.md) | How to validate a major openclaw release locally before pushing to ACI |
| 2026-05-07 | [Smoke tooling inventory](./2026-05-07-openclaw-smoke-tooling-inventory.md) | Exact JSON shapes for `plugins inspect`, `status --deep`, `infer model run`. Reference when extending smoke probes. |
| 2026-05-09 | [Codex harness missing in 2026.5.x](./2026-05-09-codex-harness-missing.md) | If embedded agent turns (Telegram, Web UI) fail silently with `[assistant turn failed before producing content]` or `Requested agent harness "codex" is not registered` |

## Adding your own

When you debug a production issue that took more than an hour to figure out,
write it up here. The format that works: state the problem, show the wrong
hypotheses, name the diagnostic command that gave the answer, and end with a
heuristic ("when X symptom, do Y first"). Future-you will thank present-you.
