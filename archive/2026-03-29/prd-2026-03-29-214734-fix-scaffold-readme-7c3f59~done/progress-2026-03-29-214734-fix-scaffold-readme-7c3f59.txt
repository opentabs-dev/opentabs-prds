# Ralph Progress Log
PRD: prd-2026-03-29-214734-fix-scaffold-readme-7c3f59~running.json
Started: Mon Mar 30 04:48:06 UTC 2026
---

## 2026-03-30 - US-001
- Fixed `generateReadme` in `platform/cli/src/scaffold.ts` line 300: removed `@opentabs-dev/` scope prefix from the `npm install -g` command
- Added test in `platform/cli/src/scaffold.test.ts` verifying the generated README contains `npm install -g opentabs-plugin-<name>` without the scoped prefix
- All Phase 1 checks passed (build, type-check, lint, knip, test)
- **Learnings for future iterations:**
  - The `generateReadme` function is at line 282 in `platform/cli/src/scaffold.ts`
  - Scaffolded plugins use unscoped package names (`opentabs-plugin-<name>`); the `@opentabs-dev/` scope is reserved for officially published platform packages
  - The `opentabs plugin install` command (line 294) is correct as-is — it resolves both scoped and unscoped names via `resolvePluginPackageCandidates`
---
