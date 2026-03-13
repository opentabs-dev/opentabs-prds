## Codebase Patterns
- README generation: `cd plugins/<name> && npm install && npm run build && node ../../platform/plugin-tools/dist/cli.js readme`
- Use repo-local cli.js (NOT npx opentabs-plugin) — published version lacks readme command
- Build produces dist/tools.json with 14 tools metadata; readme command reads it to generate Phase 6 format
---

## [2026-03-13] - US-001
- Generated Phase 6 README for facebook plugin (14 tools, grouped into 10 categories)
- Files changed: plugins/facebook/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; `npm install` + `npm run build` + readme command is straightforward
  - The readme command outputs directly to README.md in the current directory (plugins/<name>)
  - Phase 6 format includes: Install section, Setup section, grouped Tools table, How It Works, License
---

## [2026-03-13] - US-002
- Generated Phase 6 README for fidelity plugin (13 tools, grouped into 4 categories)
- Files changed: plugins/fidelity/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as facebook plugin
  - 13 tools grouped as: Portfolio (4), Account (3), Market Data (5), Retirement (1)
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-003
- Generated Phase 6 README for figma plugin (14 tools, grouped into 4 categories)
- Files changed: plugins/figma/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 14 tools grouped as: Users (1), Teams (3), Files (8), Comments (2)
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-004
- Generated Phase 6 README for gemini plugin (6 tools, grouped into 4 categories)
- Files changed: plugins/gemini/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 6 tools grouped as: Account (1), Models (1), Conversations (3), Chat (1)
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-005
- Generated Phase 6 README for github plugin (35 tools, grouped into multiple categories)
- Files changed: plugins/github/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 35 tools — largest plugin so far; includes Repositories (11), Issues, PRs, etc.
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-006
- Generated Phase 6 README for gitlab plugin (22 tools, grouped into multiple categories)
- Files changed: plugins/gitlab/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 22 tools — includes Issues, MRs, Repositories, CI/CD, etc.
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-007
- Generated Phase 6 README for google-analytics plugin (8 tools, grouped into 2 categories)
- Files changed: plugins/google-analytics/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 8 tools grouped as: Account (3), Reporting (5)
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-008
- Generated Phase 6 README for google-calendar plugin (18 tools)
- Files changed: plugins/google-calendar/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 18 tools — largest yet in this batch
  - README generated cleanly with no scaffold boilerplate remaining
---

## [2026-03-13] - US-009
- Generated Phase 6 README for google-cloud plugin (30 tools)
- Files changed: plugins/google-cloud/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 30 tools — largest plugin in this batch
  - README generated cleanly with no scaffold boilerplate remaining
---
## [2026-03-13] - US-010
- Generated Phase 6 README for google-drive plugin (17 tools)
- Files changed: plugins/google-drive/README.md
- **Learnings for future iterations:**
  - Build succeeds without issues; same pattern as previous plugins
  - 17 tools — larger than most in this batch
  - README generated cleanly with no scaffold boilerplate remaining
---
