# custos-pay-skill

A drag-and-drop skill that points your AI agent (Claude, Gemini, OpenAI/Codex,
Cursor, Windsurf) at any Custos-Pay-compatible LLM gateway, with built-in
balance monitoring and automatic top-up.

The skill ships **no credentials**. You supply your own keys during setup.

---

## Quick install

### Option A — drag & drop

Drop the `custos-pay-skill/` folder onto your agent's chat window.
The agent immediately starts the configuration flow — no extra prompt needed.

### Option B — manual copy

```bash
# Claude Code / Claude Desktop
cp -R custos-pay-skill ~/.claude/skills/

# Cursor
cp -R custos-pay-skill ~/.cursor/skills/

# Windsurf
cp -R custos-pay-skill ~/.codeium/windsurf/skills/

# Gemini CLI
cp -R custos-pay-skill ~/.gemini/skills/

# OpenAI Codex / generic
mkdir -p ~/.config/agent-skills
cp -R custos-pay-skill ~/.config/agent-skills/
```

### Option C — let the skill install itself

```bash
cd custos-pay-skill
bash scripts/self-install.sh
```

### Option D — run configure directly

```bash
bash custos-pay-skill/scripts/configure.sh
```

---

## Configuration flow

Once the agent detects the skill folder (or you run `configure.sh`), it walks
you through five steps in order.

### Step 1 — Choose your platform

The agent detects which tool you are running in and highlights it as the
recommended default. Just press Enter to accept, or type the number for a
different platform:

```
Which platform do you want to connect to your Custos Pay gateway?

  1) Claude            — Claude Code / Claude Desktop   ← (Recommended — detected)
  2) Gemini            — Gemini CLI / Gemini Code Assist
  3) OpenAI / Codex    — OpenAI Codex / any OpenAI-compatible client
  4) Cursor / Windsurf — auto-resolved to whichever IDE is installed
```

If you pick **4** and both Cursor and Windsurf are installed, you will be asked
one follow-up question to pick the IDE. Otherwise it resolves automatically.

### Step 2 — Enter your LLM gateway credentials

You will be prompted for two values:

| Prompt | What it is | Where to find it |
|--------|-----------|------------------|
| `MALL_BASE_URL` | Base URL of your LLM gateway | AiCard dashboard → Mall tab → **Skill** button → **Skill includes** → Copy All |
| `MALL_AUTH_TOKEN` | Service key that authenticates your agent to the gateway | Same modal, or Mall tab → **LLM Key** button to generate / regenerate |

Example value: `MALL_BASE_URL` = `https://api.credo.aicard.credit`

The token is entered in hidden mode (no echo). It is masked to `****<last4>`
in all preview output and never written to logs.

### Step 3 — Config is written to disk

The script shows a one-line preview of what it will write and asks for
confirmation before touching any files.

| Platform | Files written |
|----------|---------------|
| Claude | `~/.zshrc` (or `~/.bashrc` / fish config) + `~/.claude/settings.json` |
| Gemini | shell rc + `~/.gemini/settings.json` |
| OpenAI / Codex | shell rc + `~/.codex/config.toml` |
| Cursor | `~/.cursor/mcp.json` |
| Windsurf | `~/.codeium/windsurf/custos-pay-provider.json` |

The shell rc file is updated idempotently — any previous `custos-pay-skill`
block is replaced, not duplicated. For Claude, the same keys are also merged
into `settings.json` so Claude Code picks them up immediately without a
terminal restart.

### Step 4 — LLM routing is verified

The script calls `verify.sh` which makes one authenticated request to your
gateway and reports the HTTP status:

```
agent: claude
GET   : https://api.credo.aicard.credit/v1/models

HTTP status: 200
ok
```

**Verify exit codes and what they mean:**

| HTTP status | Message | Fix |
|-------------|---------|-----|
| `2xx` | ok | — |
| `401` / `403` | auth rejected — token likely wrong | Re-run configure and re-enter `MALL_AUTH_TOKEN`; use the **LLM Key** button in the dashboard to regenerate if needed |
| `404` | endpoint not found — check MALL_BASE_URL path | Confirm the gateway base URL with your provider |
| `000` | no response — DNS or TLS error | Check your network; confirm `MALL_BASE_URL` is reachable |

Even if verify returns non-2xx, the config is already written. Fix the value
and run `bash scripts/verify.sh` again at any time.

### Step 5 — Balance monitoring and auto-recharge (optional, recommended)

After LLM routing is live, the script offers to set up balance monitoring so
your agent never runs out of credits mid-task.

You will be prompted for three more values:

| Prompt | What it is | Where to find it |
|--------|-----------|------------------|
| `CUSTOS_BASE_URL` | AiCard platform base URL | Mall tab → **Skill** button → **Skill includes** → Copy All |
| `CUSTOS_API_KEY` | Your agent's Custos API key | Same modal |
| `CUSTOS_SECRET_KEY` | Your agent's Custos secret key (used for HMAC auth) | Same modal |

Then the script asks for an **auto-recharge threshold** (default `0.5`): when
your mall balance drops below this many credits, a top-up is triggered
automatically.

Press **Enter** at the `CUSTOS_BASE_URL` prompt to skip Step 5 and finish.
You can come back and run `bash scripts/configure.sh` again to add it later.

After writing the vars, the script:
1. Runs `check-balance.sh` once to confirm connectivity and prints your current balance.
2. Starts `auto-recharge.sh` in the background with your chosen threshold.

**All five values** (`MALL_BASE_URL`, `MALL_AUTH_TOKEN`, `CUSTOS_BASE_URL`,
`CUSTOS_API_KEY`, `CUSTOS_SECRET_KEY`) are available together via the
**"Copy All"** button in the Skill Setup modal.

---

## Individual scripts

### `bash scripts/verify.sh`

Round-trips the configured LLM gateway and reports HTTP status.
The token is never printed. Useful after changing credentials.

### `bash scripts/check-balance.sh`

Authenticates with your Custos credentials (HMAC-signed token exchange) and
prints the current mall credit balance.

```
balance: 3.4968336 USD
agent:   ag_8d1dcc9885aed6f5
url:     https://aicard.credit
```

Requires: `CUSTOS_BASE_URL`, `CUSTOS_API_KEY`, `CUSTOS_SECRET_KEY`

**Exit codes:**

| Code | Meaning | Fix |
|------|---------|-----|
| `0` | Success | — |
| `1` | Auth or API error | Check credentials; see printed error for HTTP status |
| `2` | Missing env var | `source ~/.zshrc` first, or re-run `configure.sh` |

### `bash scripts/auto-recharge.sh [threshold] [interval_seconds]`

Monitors your balance every `interval_seconds` (default 300) and calls the
recharge API whenever it drops below `threshold` credits (default 0.5).

```bash
# Run in the background
bash scripts/auto-recharge.sh 0.5 300 &

# Stop it
kill %1   # or kill <PID printed on startup>
```

---

## Error reference

### Auth errors (Steps 2–4 / verify)

| Situation | Message | Fix |
|-----------|---------|-----|
| Wrong `MALL_AUTH_TOKEN` | `HTTP 401` or `HTTP 403` | Re-enter via `configure.sh`; use **LLM Key** to regenerate |
| Wrong `MALL_BASE_URL` | `HTTP 404` or DNS error (`000`) | Confirm the gateway URL with your provider |
| Gateway offline | `HTTP 000` — no response | Check your network or try again later |

### Balance check errors (Step 5 / check-balance.sh)

| Situation | Message | Fix |
|-----------|---------|-----|
| Wrong Custos credentials | `Auth failed (HTTP 401)` | Re-enter `CUSTOS_API_KEY` / `CUSTOS_SECRET_KEY` via `configure.sh` |
| `CUSTOS_BASE_URL` wrong | `Connection error — check CUSTOS_BASE_URL` | Verify the URL matches the AiCard platform |
| `openssl` not installed | `openssl not found — cannot sign request` | Install openssl: `brew install openssl` (macOS) or `apt install openssl` (Linux) |
| `CUSTOS_BASE_URL` is a dev/staging server requiring a browser session | `API error 401: Unauthorized — session required` | Use the production URL, not a staging environment |

### Auto-recharge errors (auto-recharge.sh)

When a recharge attempt fails, the script shows a desktop notification (macOS)
or a terminal banner (all platforms) and prints the reason:

| HTTP status | Situation | Message shown | Fix |
|-------------|-----------|---------------|-----|
| `402` | SpendPermission not set up | `SpendPermission not set up — grant one in the AiCard Dashboard → Developer tab` | Set up a SpendPermission for this agent in the AiCard dashboard |
| `402` | Monthly recharge quota reached | `Recharge quota reached — top up your limit in AiCard Dashboard → Admin → Mall` | Increase the quota or wait for the quota to reset |
| `403` | API key lacks permission | `Access denied — check CUSTOS_API_KEY and account permissions` | Verify the key and agent permissions in the dashboard |
| `429` | Too many recharge attempts | `Rate limit hit — will retry next interval` | No action needed; the script retries automatically |
| `5xx` | Insufficient on-chain USDC | `Insufficient on-chain USDC — top up the smart account wallet on Base` | Fund your agent's smart account wallet on Base |
| `5xx` | Recharge quota fence hit | `Recharge quota fence hit — only partial credit remaining` | Check quota status in AiCard Dashboard → Admin → Mall |
| `5xx` (other) | Gateway error | `Gateway error — relay or CDP may be temporarily unavailable` | Transient; the script retries automatically next interval |

**Notification behavior:** The script notifies on the first failure, then again
every 3 consecutive failures. The counter resets silently once the balance is
healthy.

---

## Supported hosts

| Host | Env vars written | Config file merged |
|------|-----------------|-------------------|
| Claude Code | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` | `~/.claude/settings.json` |
| Claude Desktop | same | same |
| Gemini CLI / Code Assist | `GOOGLE_GEMINI_BASE_URL` + `GEMINI_API_KEY` | `~/.gemini/settings.json` |
| OpenAI Codex / generic | `OPENAI_BASE_URL` + `OPENAI_API_KEY` | `~/.codex/config.toml` |
| Cursor | — | `~/.cursor/mcp.json` |
| Windsurf | — | `~/.codeium/windsurf/custos-pay-provider.json` |

---

## Security

- Credentials never leave your machine.
- The skill repository contains zero secrets.
- Tokens are entered in hidden mode (no echo) and masked to `****<last4>` in
  all preview output.
- JSON request bodies are built via Python environment variables — credentials
  are never passed through process argv where they could appear in `ps` output.
- Config writes are previewed and require confirmation before executing.
- `.gitignore` is updated automatically when writing into a git repo.

---

## File layout

```
custos-pay-skill/
├── SKILL.md           — agent entry point (read by Claude, Gemini, Codex, etc.)
├── AGENTS.md          — same, for agents that look for AGENTS.md
├── README.md          — this file
├── manifest.json      — cross-platform metadata
├── configs/           — example config file templates
└── scripts/
    ├── self-install.sh    copy this folder to the host agent's skill dir
    ├── detect-agent.sh    print: claude|gemini|openai|cursor|windsurf|unknown
    ├── configure.sh       interactive Steps 1–5 flow
    ├── verify.sh          one round-trip against the LLM gateway
    ├── check-balance.sh   query current mall credit balance
    └── auto-recharge.sh   monitor balance; top up automatically when below threshold
```
