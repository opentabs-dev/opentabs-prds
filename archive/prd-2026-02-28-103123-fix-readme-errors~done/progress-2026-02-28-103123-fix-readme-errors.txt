## Codebase Patterns
- README.md only file changed; all quality checks pass for markdown-only edits since there are no TypeScript changes
- The `opentabs plugin install` CLI command resolves shorthand plugin names (e.g. `slack`) automatically
- The correct Claude Code MCP config path is `~/.claude/settings/mcp.json`, not `~/.claude.json`
- Plugin dev workflow: `npm run dev` in plugin directory auto-rebuilds and notifies server via `POST /reload`

# Ralph Progress Log
PRD: prd-2026-02-28-103123-fix-readme-errors~running.json
Started: Sat Feb 28 18:33:15 UTC 2026
---

## 2026-02-28 - US-001
- Fixed all 6 factual errors in README.md:
  1. Line 31: Changed '36 built-in browser tools' → '39' (matches server health endpoint and docs site)
  2. Line 64: Added `--show-secret` flag to `opentabs config show --json` command
  3. Line 67: Changed `~/.claude.json` → `~/.claude/settings/mcp.json` (correct Claude Code config path)
  4. Line 87: Changed `npm install -g opentabs-plugin-slack` → `opentabs plugin install slack`
  5. Line 88: Removed redundant `opentabs start` (server already running from earlier step)
  6. Lines 122-126: Replaced nonexistent `opentabs start --dev` with `npm run dev` and accurate description
- Files changed: README.md
- **Learnings for future iterations:**
  - README.md is the only file changed; all five Phase 1 checks pass trivially for markdown-only edits
  - The prettier pre-commit hook reformats markdown automatically (minor whitespace tweaks)
  - The acceptance criteria in this PRD describes the desired end state ("should say X instead of Y"), not the current state
---
