# Telegram setup

> When to read this: after you've finished the basic DM setup in
> [getting-started.md §4](getting-started.md#4-telegram-bot) and want to
> add groups, forum topics, or per-topic agent routing.

## Concepts

OpenClaw's Telegram channel supports three layers of access control:

1. **DMs** — `dmPolicy: "allowlist" | "open"` plus `allowFrom: [<userIds>]`.
2. **Groups** — per-chat-id config with `groupPolicy`, `requireMention`,
   `allowFrom`, optional `topics`.
3. **Topics** (forum supergroups only) — per-`message_thread_id` config
   with the same fields, plus `agentId` for per-topic agent routing.

The default template ships with DM allowlist for `${TELEGRAM_OWNER_ID}`
and an empty `groups: {}`. Add groups by editing
`config/config.template.json` and redeploying.

## Add a group

Edit `config/config.template.json` so `channels.telegram.groups` looks
like this:

```json
"groups": {
  "-1001234567890": {
    "groupPolicy": "open",
    "requireMention": false
  }
}
```

The chat ID is negative for groups/supergroups. Get it by:

1. Add the bot to the group.
2. Send any message in the group.
3. `curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | jq`.

The `chat.id` field on the most recent message is your group ID.

`groupPolicy` accepts `"open"` (any group member can talk) or
`"allowlist"` (only `allowFrom` user IDs).

## Add forum topics

A *forum* supergroup has `is_forum: true` (set in Telegram via Group
Settings → Topics). Each forum topic has a numeric `message_thread_id`.
List your topics by sending one message in each and watching
`getUpdates` for the `message_thread_id` field.

Add per-topic config:

```json
"groups": {
  "-1001234567890": {
    "groupPolicy": "open",
    "requireMention": false,
    "topics": {
      "5":  { "systemPrompt": "Topic: Travel — trip planning, itineraries." },
      "12": { "systemPrompt": "Topic: Health — wellness, medical." }
    }
  }
}
```

Topic-level fields override group-level fields. Forum topics auto-isolate
agent sessions via the `:topic:<id>` session-key suffix, so each topic
gets its own conversation history without any extra config.

If a topic isn't listed under `topics`, the group-level defaults apply
(it still works — listing is only required for overrides).

## Per-topic agent routing

Route a single topic to a different agent (the agent must exist in
`agents.list`):

```json
"topics": {
  "5":  { "agentId": "main",   "systemPrompt": "..." },
  "12": { "agentId": "gemini", "systemPrompt": "..." }
}
```

## Bot must be admin in forum supergroups

In a forum supergroup with topics, a regular-member bot can read every
topic but **cannot post** in topics whose admin-set permissions block
non-admins. Symptom: "bot replies in some topics but not others".

Fix: promote the bot to admin with at minimum:

- ✅ Send Messages
- ✅ Manage Topics

That's enough for the bot to post into any topic, including ones created
later.

## Tightening access later

Switch to mention-required (only replies on `@yourBot ...`):

```json
"requireMention": true
```

Restrict to specific users:

```json
"groupPolicy": "allowlist",
"allowFrom": ["123456789", "987654321"]
```

Both can also be set at topic level for finer control.

## Multi-bot setups

If you operate more than one bot, point each one at its own deployment
(separate `CONTAINER` / `DNS_LABEL`). Cross-bot routing within a single
OpenClaw deployment is not supported.

## Reference

The full TypeScript schema for Telegram config lives in OpenClaw's
[`src/config/types.telegram.ts`](https://github.com/openclaw/openclaw/blob/main/src/config/types.telegram.ts).
