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

### Never delete remote branches without asking

Do not delete remote git branches unless the user explicitly says to. This
applies everywhere: CLI, scripts, consolidator, consumer. Even if a branch
has been merged, ask before deleting.

### Never use --no-verify

Never use `git push --no-verify` or `git commit --no-verify`. Git hooks
exist for a reason. If the hook fails, fix the problem — do not skip the
hook.

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

---

## Systemd Services (PC)

Both the consumer and consolidator run as systemd services on the PC. **Never
launch them manually** with `nohup ./consumer.sh` or `./consolidator.sh` —
this creates a rogue process that holds the PID lock, causing the systemd
service to fail on every restart attempt.

### Managing services

```bash
# Restart (picks up latest code from ~/workspace/opentabs-prds)
sudo systemctl restart ralph-consumer
sudo systemctl restart ralph-consolidator

# Check status
systemctl status ralph-consumer
systemctl status ralph-consolidator

# View logs (systemd journal)
sudo journalctl -u ralph-consumer --since '10 min ago' --no-pager
sudo journalctl -u ralph-consolidator --since '10 min ago' --no-pager
```

### Service files

- `/etc/systemd/system/ralph-consumer.service`
- `/etc/systemd/system/ralph-consolidator.service`

Both have `Restart=always` and `RestartSec=10`. After a code change, run
`sudo systemctl restart <service>` — the service re-reads the script from
disk on each start.

### Common pitfall: stale PID lock

If you see repeated "Error: consolidator.sh is already running (PID ...)"
in the logs, it means a manually-launched instance is holding the PID lock.
Find and kill the rogue process, then let systemd manage the service:

```bash
# Find the rogue process
ps aux | grep consolidator.sh | grep -v grep

# Kill it (the systemd service will auto-start within 10s)
kill <pid>
```

---

## Docker Worker Image

The worker Docker image (`ralph-worker:latest`) is built from
`.ralph/Dockerfile` in the **code repo** (opentabs), not this repo.

### Rebuilding the image

```bash
ssh pc "cd ~/.ralph-consumer/code && docker build -t ralph-worker -f .ralph/Dockerfile ."
```

### Known constraints

- **Node version must match the project**: The image must use the same
  Node.js major version as the project's `package-lock.json` was generated
  with. A mismatch causes lockfile drift on every `npm install`. The
  Dockerfile pins Node via `n` (e.g., `n 22`).

- **Never bind-mount directly into `/tmp/worker/`**: Docker creates
  intermediate directories for bind mounts as root. Since the container
  runs as `ubuntu` (uid 1000) with `HOME=/tmp/worker`, mounting into
  `/tmp/worker/` makes it root-owned and breaks all writes. Always mount
  into `/tmp/staging/` and copy during `CONTAINER_INIT`.

- **SSH credentials**: The host's `~/.ssh/config` and private keys are
  mounted read-only into `/tmp/staging/` and copied into
  `/tmp/worker/.ssh/` at container startup with correct permissions
  (700 for dir, 600 for keys). If an `ssh-agent` is available, its socket
  is also forwarded.

---

## Deploying Code Changes

After committing and pushing changes to consumer.sh or consolidator.sh:

```bash
# 1. Pull on PC
ssh pc "cd ~/workspace/opentabs-prds && git pull"

# 2. Restart the affected service(s)
ssh pc "sudo systemctl restart ralph-consumer"
ssh pc "sudo systemctl restart ralph-consolidator"

# 3. Verify
ssh pc "systemctl status ralph-consumer"
ssh pc "systemctl status ralph-consolidator"
```

For Dockerfile changes (in the code repo), also rebuild the image before
restarting the consumer.
