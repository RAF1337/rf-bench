# Harness profile format

A harness profile is the only way harness content (CLAUDE.md, rules, skills, agents, hooks,
plugins, MCP servers) reaches the agent. The base prompt is the same for every profile.

```
profiles/<name>/
  profile.json     optional; all keys optional
  user/            copied into the run's clean CLAUDE_CONFIG_DIR (acts as ~/.claude)
  project/         copied into the agent workspace root (acts as the project)
```

## profile.json

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `description` | string | `""` | Free text. |
| `allowWeb` | bool | `false` | When `false`, the runner denies `WebFetch` and `WebSearch`. Recorded in the run. |
| `mcpMode` | `strict` \| `open` | `strict` | `strict`: only the servers in `mcpServers` (`--mcp-config` + `--strict-mcp-config`), claude.ai connectors off. `open`: those servers plus whatever the environment provides (for example claude.ai connectors). |
| `mcpServers` | object | `{}` | `name -> server config`, same shape as the `mcpServers` object of a Claude Code `.mcp.json`. Written to `<claude-home>/rfbench-mcp.json` as `{"mcpServers": {...}}` and passed with `--mcp-config`. |
| `plugins` | array | `[]` | `{ "name", "marketplace", "marketplaceSource" }`. For each plugin the runner runs `claude plugin marketplace add <marketplaceSource>` (once per source) and `claude plugin install <name>@<marketplace>` with `CLAUDE_CONFIG_DIR` set to the run's clean config dir, then reads versions from `claude plugin list --json`. `marketplaceSource` is anything `marketplace add` accepts: `owner/repo`, a git or https URL, or a local path. `marketplace` is the marketplace's declared name. |

Example:

```json
{
  "description": "AL rules + MS Learn MCP",
  "allowWeb": false,
  "mcpMode": "strict",
  "mcpServers": {
    "mslearn": { "type": "http", "url": "https://learn.microsoft.com/api/mcp" }
  },
  "plugins": [
    { "name": "al-rules", "marketplace": "rf-market", "marketplaceSource": "rf/claude-market" }
  ]
}
```

## user/

Copied as-is into `%TEMP%\rf-bench\<runId>\<taskId>\<repeat>\claude-home`, which is the
agent's `CLAUDE_CONFIG_DIR`. Typical content: `CLAUDE.md`, `rules/`, `skills/`, `agents/`,
`commands/`, `settings.json`. A file whose name contains `credentials` is refused: auth goes
through environment variables only.

## project/

Copied as-is into the workspace (`...\ws`), next to `TASK.md` and `app/`. Typical content:
`CLAUDE.md`, `.claude/settings.json`, `.claude/rules/`, `.claude/skills/`. Do not use
`.mcp.json` for MCP servers: strict mode ignores it; use `mcpServers`. A file that would overwrite a task file
(for example `TASK.md` or `app/app.json`) is refused.

`project/.claude/settings.json` is merged by the runner (see below); every other key in it is
kept.

## What the runner adds (cannot be loosened by a profile)

Written into `ws/.claude/settings.json` after the profile is copied. Runner deny rules come
last; profile `allow` entries that overlap a runner deny rule are removed (same rule, an
absolute `Read`/`Edit` path that covers or lies inside a denied path, a `Bash`/`PowerShell`
pattern matched by a denied pattern, or any `WebFetch`/`WebSearch` rule when web is denied).
Bare tool names (`Read`) and relative paths are kept; deny still wins at runtime.

- `permissions.deny`:
  - `Read(<repo>/**)`, `Edit(<repo>/**)` in two spellings: `C:/GeneralDev/AL/rf-bench/**` and
    the documented absolute form `//c/GeneralDev/AL/rf-bench/**`;
  - the same `Read`/`Edit` pair for the run's `grader` folder;
  - `Edit(<ws>/.claude/settings*.json)` and `Edit(<claude-home>/settings*.json)` so the agent
    cannot remove these rules (`bypassPermissions` otherwise allows writes to `.claude/`);
  - `Bash(*rf-bench*)`, `PowerShell(*rf-bench*)`, `Bash(*\grader*)`, `PowerShell(*\grader*)`,
    `Bash(*/grader*)`, `PowerShell(*/grader*)`;
  - `WebFetch`, `WebSearch` unless `allowWeb: true`.
- `disableClaudeAiConnectors: true` in `strict` mode.
- `claudeMdExcludes`: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.claude/CLAUDE.md`,
  `.claude/CLAUDE.local.md`, `.claude/rules/**` of every folder above the workspace (both
  `C:/...` and `/c/...` spellings). `%TEMP%` lies under the user's home, so without this the
  user's `~\.claude\CLAUDE.md` could be loaded as an ancestor project file.

The workspace is also `git init`-ed, so Claude Code's parent-folder walk for project skills
stops at the workspace ("up to the repository root") and cannot reach `~\.claude\skills`.

Agent environment (`Get-AgentEnvironment`): `CLAUDE_CONFIG_DIR=<claude-home>`,
`DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1`, the auth
variable for `auth.mode` (the other auth variable is set to `$null` = removed from the child
process), and `ENABLE_CLAUDEAI_MCP_SERVERS=false` in `strict` mode.

## Verification of Claude Code behaviour (2026-11-04, CLI 2.1.318)

| Item | Finding | Source |
| --- | --- | --- |
| Env var that turns off claude.ai connectors | `ENABLE_CLAUDEAI_MCP_SERVERS` — "Set to `false` to stop Claude Code from fetching claude.ai MCP servers. Enabled by default for logged-in users." Brief's name is correct. | https://code.claude.com/docs/en/env-vars |
| Settings equivalent | `"disableClaudeAiConnectors": true`, honoured in any settings file, same effect as the env var. Neither affects connectors delivered by a cloud host or the desktop app. | https://code.claude.com/docs/en/mcp (Disable claude.ai connectors) |
| `--strict-mcp-config` | "Claude Code then uses only the MCP servers you pass with `--mcp-config`." | https://code.claude.com/docs/en/mcp |
| `DISABLE_AUTOUPDATER` | "Set to `1` to disable automatic background updates." | https://code.claude.com/docs/en/env-vars |
| `CLAUDE_CONFIG_DIR` | "Override the configuration directory (default: `~/.claude`). All settings, session history, and plugins are stored under this path." | https://code.claude.com/docs/en/env-vars |
| `ANTHROPIC_API_KEY` vs subscription | "When set, this key is used instead of your … subscription even if you are logged in. In non-interactive mode (`-p`), the key is always used when present." Hence the runner removes it in `subscription` mode. | https://code.claude.com/docs/en/env-vars |
| `claude plugin marketplace add <source>` | Exists; source = URL, path or GitHub repo; `--scope` default `user`. | `claude plugin marketplace add --help` |
| `claude plugin install <plugin>` | Exists; `plugin@marketplace` form; scope default `user`; `-y` only needed for marketplace-declared *command* sources when not on a TTY. | `claude plugin install --help` |
| `claude plugin list --json` | Exists. Output is an array of `{id: "name@marketplace", version, scope, enabled, installPath, ...}`. Verified by installing a local test plugin into a scratch `CLAUDE_CONFIG_DIR` (never the real `~/.claude`). Text fallback parses `❯ name@marketplace` / `Version: x`. | `claude plugin list --help`, local run |
| Permission rule order | "Rules are evaluated in order: deny, then ask, then allow. … An allow rule can't carve an exception out of a deny rule." | https://code.claude.com/docs/en/permissions |
| Absolute paths in `Read`/`Edit` rules | `//path` is absolute; a single `/` anchors at the settings source. "On Windows, paths are normalized to POSIX form before matching. `C:\Users\alice` becomes `/c/Users/alice`". So the documented form is `Read(//c/GeneralDev/AL/rf-bench/**)`. The brief's `C:/...` spelling is kept as well but is not the documented form. | https://code.claude.com/docs/en/permissions (How path patterns match) |
| `Read` deny coverage | Applies to Read, Grep, Glob (best effort), blocks Edit/Write on the same path, and to file commands Claude Code recognises in Bash (`cat`, `head`, …). Not to scripts that open files themselves. `Glob(path)` rules never match. | https://code.claude.com/docs/en/permissions |
| `Bash(...)`/`PowerShell(...)` patterns | `*` wildcards anywhere (`Bash(* --version)` is a documented example); PowerShell rules "use the same shape as Bash rules", case-insensitive, aliases canonicalised. Bash rules do not match `sh -c '…'` wrappers or the program by full path. | https://code.claude.com/docs/en/permissions |
| `bypassPermissions` and deny rules | Mode "skips permission prompts"; deny rules are still evaluated first. It also allows writes to `.claude/`, hence the settings-file `Edit` denies. | https://code.claude.com/docs/en/permissions |
| Ancestor `CLAUDE.md` | "Claude Code loads `CLAUDE.md` and `CLAUDE.local.md` from your current working directory and every directory above it." `claudeMdExcludes` takes absolute-path globs in any settings layer. | https://code.claude.com/docs/en/memory |
| Ancestor skills | "loads project skills from `.claude/skills/` in the directory where you start it and in every parent directory up to the repository root". | https://code.claude.com/docs/en/skills |

Not verified by a live session (running real agent sessions was out of scope): whether
`claudeMdExcludes` matches the `C:/...` or the `/c/...` spelling on Windows (both are written),
and whether the ancestor walk includes `.claude/CLAUDE.md` of a parent folder. The transcript
leak scan (Task 8) is the backstop.
