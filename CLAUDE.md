# Project Instructions for Claude

## Destructive Actions Require Confirmation

Never perform destructive or irreversible actions without explicit user
confirmation. This includes but is not limited to:

- Deleting remote git branches
- Force-pushing
- Dropping/resetting commits that have been pushed
- Deleting files on remote servers
- Stopping/disabling services

Always ask first. Do not assume intent from context.

---

## Pulling Latest Changes

At the start of every session, pull the latest changes before doing any work:

```bash
git pull
```

This repository is configured with `pull.rebase = true`, so `git pull` automatically rebases local commits on top of the remote. If the pull fails due to conflicts, resolve them before proceeding.

---

## Git Identity

Before making any commits, verify the git identity is configured correctly:

```
git config user.name   # Must be: Ralph Wiggum
git config user.email  # Must be: ralph@opentabs.dev
```

If either value is wrong, fix it before committing:

```bash
git config user.name "Ralph Wiggum"
git config user.email "ralph@opentabs.dev"
```

## Consumer Operations

### Scaling workers without restart

The consumer supports hot-reloading the worker count via `SIGHUP`. Edit the
config file and send the signal:

```bash
# Change worker count (config is at ~/.ralph-consumer/config)
echo 'workers=6' > ~/.ralph-consumer/config

# Reload — consumer picks up the new value on next poll cycle
kill -HUP $(cat ~/.ralph-consumer/.consumer.pid)
```

**Scale up**: new slots are available immediately; PRDs are dispatched on the
next poll cycle.

**Scale down**: the cap is lowered immediately but active workers in the
higher slots are not killed — they finish their current PRD and drain
naturally.
