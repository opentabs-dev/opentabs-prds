# opentabs-prds

Git-based distributed work queue for Ralph. PRD files are the unit of work — producers publish them, distributed workers claim and execute them atomically.

## Architecture

```
┌──────────────┐     git push PRD      ┌──────────────────────┐
│   Producer   │ ──────────────────────→│  opentabs-prds repo  │
│ (Ralph skill)│                        │  (GitHub — queue)    │
└──────────────┘                        └──────┬───────────────┘
                                               │
                         ┌─────────────────────┼─────────────────────┐
                         │ git push (claim)    │                     │
                    ┌────▼─────┐          ┌────▼─────┐          ┌────▼─────┐
                    │ Worker A │          │ Worker B │          │ Worker C │
                    └────┬─────┘          └────┬─────┘          └────┬─────┘
                         │                     │                     │
                         │ git push branch     │                     │
                         ▼                     ▼                     ▼
                    ┌──────────────────────────────────────────────────────┐
                    │            opentabs repo (code)                      │
                    │  ralph-* branches pushed by workers                  │
                    └──────────────────┬──────────────────────────────────┘
                                       │
                                  ┌────▼──────────┐
                                  │ Consolidator  │
                                  │ merges ralph-*│
                                  │ into main     │
                                  └───────────────┘
```

## PRD State Machine

```
prd-<slug>~draft.json           → Producer is writing (not committed)
prd-<ts>-<slug>.json            → Ready for pickup (committed + pushed)
prd-<ts>-<slug>~running.json   → Claimed by a worker (atomic via git push)
prd-<ts>-<slug>~done.json      → Completed
→ archive/                       → Final resting place
```

## Atomicity

`git push` to a single branch is serialized by GitHub. When two workers try to claim the same PRD simultaneously, the first push wins and the second gets a non-fast-forward rejection — a natural compare-and-swap. The losing worker retries with a different PRD.

## Scripts

### producer.sh — Publish PRDs

```bash
# Publish a draft PRD (auto-adds timestamp)
./producer.sh prd-my-feature~draft.json

# Publish multiple PRDs
./producer.sh prd-feature-a~draft.json prd-feature-b~draft.json
```

### consumer.sh — Claim and Execute PRDs

```bash
# Start a worker daemon (Docker isolation, 2 parallel workers)
./consumer.sh --code-repo https://github.com/opentabs-dev/opentabs.git

# Single batch, no Docker, 3 workers
./consumer.sh --code-repo https://github.com/opentabs-dev/opentabs.git \
  --once --no-docker --workers 3

# Full options
./consumer.sh \
  --code-repo https://github.com/opentabs-dev/opentabs.git \
  --queue-repo https://github.com/opentabs-dev/opentabs-prds.git \
  --tool claude \
  --model claude-sonnet-4-20250514 \
  --workers 2 \
  --poll 10 \
  --worker-id my-machine-01
```

### consolidator.sh — Merge Branches into Main

```bash
# Merge all available ralph-* branches and exit
./consolidator.sh --code-repo https://github.com/opentabs-dev/opentabs.git --once

# Run as daemon, check every 30s
./consolidator.sh --code-repo https://github.com/opentabs-dev/opentabs.git

# Dry run — show what would be merged
./consolidator.sh --code-repo https://github.com/opentabs-dev/opentabs.git --dry-run --once
```

## Directory Structure

```
opentabs-prds/
├── producer.sh           # Publish PRDs to the queue
├── consumer.sh           # Claim + execute PRDs (distributed workers)
├── consolidator.sh       # Merge completed branches into main
├── prd-*.json            # Ready PRDs (waiting for workers)
├── prd-*~running.json    # PRDs being executed
├── prd-*~done.json       # Completed PRDs (pre-archive)
├── progress-*.txt        # Worker progress logs
├── archive/              # Completed and archived PRDs
└── README.md
```

## Worker Data Locations

Each consumer stores its working data in `~/.ralph-consumer/`:

- `queue/` — local clone of opentabs-prds
- `code/` — local clone of opentabs
- `worktrees/` — git worktrees for each active PRD
- `consumer.log` — worker log output

The consolidator stores its data in `~/.ralph-consolidator/`:

- `code/` — local clone of opentabs
- `conflicts/` — merge conflict breadcrumb files
- `consolidator.log` — consolidator log output
