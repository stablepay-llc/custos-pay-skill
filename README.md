# custos-pay-skill

A drag-and-drop skill that points your AI Agent (Claude, Gemini, OpenAI/Codex,
Cursor, Windsurf) at any Custos-Pay-compatible LLM gateway.

The skill ships **no credentials**. You supply `MALL_BASE_URL` and `MALL_AUTH_TOKEN`.

## What it does

When the Agent sees this skill, it **immediately runs the configure flow**
(it does not stop to ask "what would you like me to do" — the presence of
the skill is the instruction):

1. **Self-installs** into the host agent's skill directory if not already there.
2. **Asks which platform** to configure — exactly four grouped options:
   (1) Claude (Code / Desktop), (2) Gemini (CLI / Code Assist),
   (3) OpenAI / Codex / OpenAI-compatible, (4) Cursor / Windsurf.
   The detected host is pre-selected; just press Enter to accept.
3. **Prompts you for `MALL_BASE_URL` and `MALL_AUTH_TOKEN`** (the LLM gateway credentials).
4. **Writes** the platform-correct env vars / config file (e.g. appends to
   `~/.zshrc` and merges into `~/.claude/settings.json`) so the agent talks
   to your gateway instead of the vendor default.
5. **Verifies** with one round-trip and reports HTTP status (token masked).

## Quick install

### Option A — drag & drop

Drag the `custos-pay-skill/` folder onto your agent's chat window (or copy it
into the install path below). Then ask the agent:

> Please use the custos-pay-skill to configure my LLM endpoint.

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

## After install

Run the configure script, or ask the agent to do it:

```bash
bash scripts/configure.sh
```

**Step 1–4: LLM routing** — you will be prompted for:

- `MALL_BASE_URL` — your Custos Pay gateway URL (e.g. `https://api.credo.aicard.credit`)
- `MALL_AUTH_TOKEN` — your gateway token (the `sk-…` LLM service key)

**Step 5: Balance monitoring + auto-recharge** — you will be prompted for:

- `CUSTOS_BASE_URL` — the AiCard platform URL (e.g. `https://aicard.credit`)
- `CUSTOS_API_KEY` — your agent's Custos API key
- `CUSTOS_SECRET_KEY` — your agent's Custos secret key

All five values are available via the **"Copy All"** button in the
**Skill Setup** modal: AiCard dashboard → Mall tab → Skill button → Skill includes.

The script writes the right env vars / config file for the detected agent.
You can start using the agent immediately — no terminal restart needed.

## Verify

```bash
bash scripts/verify.sh
```

Performs one round-trip against the configured gateway and reports HTTP
status. The token is never echoed.

## Balance check

```bash
bash scripts/check-balance.sh
```

Authenticates with your Custos credentials (HMAC-signed token exchange) and
prints the current mall credit balance.

## Auto-recharge

```bash
bash scripts/auto-recharge.sh [threshold] [interval_seconds]
# e.g.: bash scripts/auto-recharge.sh 0.5 300 &
```

Monitors your balance every `interval_seconds` (default 300) and automatically
triggers a recharge whenever it drops below `threshold` credits (default 0.5).
Run in the background with `&`; stop with `kill %1` or `kill <PID>`.

## Supported hosts

| Host                    | Mechanism                                              |
| ----------------------- | ------------------------------------------------------ |
| Claude Code             | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`          |
| Claude Desktop          | same env vars                                          |
| Gemini CLI / Code       | `GOOGLE_GEMINI_BASE_URL` + `GEMINI_API_KEY`            |
| OpenAI Codex / generic  | `OPENAI_BASE_URL` + `OPENAI_API_KEY`                   |
| Cursor                  | Custom Model in Cursor Settings (or `~/.cursor/mcp.json`) |
| Windsurf                | Custom provider in Cascade settings                    |

## Security

- Credentials never leave your machine.
- Skill repository contains zero secrets.
- All config writes are previewed before they happen.
- `.gitignore` is updated automatically when writing into a git repo.

## Layout

See `SKILL.md` for the full file tree and the agent-facing instructions.
