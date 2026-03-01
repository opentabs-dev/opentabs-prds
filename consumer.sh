#!/bin/bash
# Consumer — distributed worker that claims and executes PRDs from the queue.
#
# Usage:
#   ./consumer.sh --code-repo <url-or-path> [options]
#
# Options:
#   --code-repo <url>    Git URL or local path for the opentabs code repo (REQUIRED)
#   --queue-repo <url>   Git URL for the queue repo (default: inferred from this script's repo)
#   --tool <name>        AI tool: "claude" or "amp" (default: claude)
#   --workers <n>        Max parallel workers (default: 4)
#   --once               Process available PRDs and exit (don't poll)
#   --poll <n>           Poll interval in seconds (default: 10)
#   --no-docker          Run workers directly on host (default: use Docker)
#   --worker-id <id>     Unique worker identifier (default: os-machineid-pid)
#
# The consumer:
#   1. Polls the opentabs-prds remote for ready PRDs
#   2. Claims a PRD atomically via git push (rename to ~running)
#   3. Creates a worktree in the code repo, executes the PRD's stories
#   4. Pushes the result branch to the code repo remote
#   5. Marks the PRD as ~done in the queue repo and pushes
#
# Atomicity: git push to a single branch is serialized by the remote.
# If two workers claim the same PRD, the first push wins and the second
# gets a non-fast-forward rejection, causing it to retry with a different PRD.

# NOTE: set -e is intentionally NOT used. This is a long-running daemon that
# must be resilient to individual command failures.

# --- Argument Parsing ---

CODE_REPO=""
QUEUE_REPO=""
TOOL="claude"
MAX_WORKERS=6
ONCE=false
POLL_INTERVAL=10
USE_DOCKER=true
# Generate a stable, privacy-safe worker ID from OS type + machine identity.
# Example: linux-0086500a-12345, darwin-a1b2c3d4-67890
_worker_os=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ -f /etc/machine-id ]; then
  _worker_machine=$(head -c 8 /etc/machine-id)
elif command -v sysctl &>/dev/null; then
  _worker_uuid=$(sysctl -n kern.uuid 2>/dev/null || echo "")
  if [ -n "$_worker_uuid" ]; then
    # sha256sum (Linux/some macOS) or shasum (macOS, Perl-based — always available)
    _worker_machine=$(echo "$_worker_uuid" | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null) | head -c 8)
    [ -z "$_worker_machine" ] && _worker_machine="unknown"
  else
    _worker_machine="unknown"
  fi
else
  _worker_machine="unknown"
fi
WORKER_ID="${_worker_os}-${_worker_machine}-$$"
unset _worker_os _worker_machine _worker_uuid

while [[ $# -gt 0 ]]; do
  case $1 in
    --code-repo)   CODE_REPO="$2";    shift 2 ;;
    --code-repo=*) CODE_REPO="${1#*=}"; shift ;;
    --queue-repo)   QUEUE_REPO="$2";   shift 2 ;;
    --queue-repo=*) QUEUE_REPO="${1#*=}"; shift ;;
    --tool)        TOOL="$2";          shift 2 ;;
    --tool=*)      TOOL="${1#*=}";     shift ;;
    --workers)     MAX_WORKERS="$2";   shift 2 ;;
    --workers=*)   MAX_WORKERS="${1#*=}"; shift ;;
    --once)        ONCE=true;          shift ;;
    --poll)        POLL_INTERVAL="$2"; shift 2 ;;
    --poll=*)      POLL_INTERVAL="${1#*=}"; shift ;;
    --no-docker)   USE_DOCKER=false;   shift ;;
    --worker-id)   WORKER_ID="$2";     shift 2 ;;
    --worker-id=*) WORKER_ID="${1#*=}"; shift ;;
    -*)            echo "Warning: unknown option: $1"; shift ;;
    *)             shift ;;
  esac
done

if [ -z "$CODE_REPO" ]; then
  echo "Error: --code-repo is required."
  echo "Usage: $0 --code-repo <git-url-or-path> [options]"
  exit 1
fi

if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: --tool must be 'amp' or 'claude' (got '$TOOL')."
  exit 1
fi

if ! [[ "$MAX_WORKERS" =~ ^[0-9]+$ ]] || [ "$MAX_WORKERS" -lt 1 ]; then
  echo "Error: --workers must be a positive integer (got '$MAX_WORKERS')."
  exit 1
fi

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [ "$POLL_INTERVAL" -lt 1 ]; then
  echo "Error: --poll must be a positive integer (got '$POLL_INTERVAL')."
  exit 1
fi

# --- Setup ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The queue repo is the directory containing this script.
# We work from a separate clone to avoid conflicts with the producer.
RALPH_TZ="${RALPH_TZ:-America/Los_Angeles}"
CONSUMER_BASE="$HOME/.ralph-consumer"
QUEUE_DIR="$CONSUMER_BASE/queue"
CODE_DIR="$CONSUMER_BASE/code"
WORKTREE_BASE="$CONSUMER_BASE/worktrees"
LOG_DIR="$CONSUMER_BASE/logs"

CONFIG_FILE="$CONSUMER_BASE/config"

mkdir -p "$CONSUMER_BASE" "$WORKTREE_BASE" "$LOG_DIR"
chmod 700 "$CONSUMER_BASE" 2>/dev/null || true

# --- Date-Rotated Logging ---
LOG_DATE=$(TZ="$RALPH_TZ" date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${LOG_DATE}.log"
ln -sf "${LOG_DATE}.log" "$LOG_DIR/latest.log"

if [ -z "${__CONSUMER_LOGGING:-}" ]; then
  export __CONSUMER_LOGGING=1
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Clean up logs older than 180 days
find "$LOG_DIR" -name '*.log' -not -name 'latest.log' -mtime +180 -delete 2>/dev/null || true

# --- Single Instance Lock ---
# Kill ALL existing consumer.sh processes (except ourselves) to prevent
# ghost instances from previous runs that weren't properly cleaned up.
# This is aggressive but safe — only one consumer should ever run.
PIDFILE="$CONSUMER_BASE/.consumer.pid"

_kill_stale_consumers() {
  local my_pid=$$
  local stale_pids
  stale_pids=$(pgrep -f 'consumer\.sh.*--code-repo' 2>/dev/null | grep -v "^${my_pid}$" || true)
  if [ -n "$stale_pids" ]; then
    echo "Warning: killing stale consumer processes: $stale_pids"
    echo "$stale_pids" | xargs kill -9 2>/dev/null || true
    # Also kill any orphaned Docker containers from stale consumers
    local _containers
    _containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^r-[0-9]{2}-' || true)
    [ -n "$_containers" ] && echo "$_containers" | xargs docker kill 2>/dev/null || true
    _containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^r-[0-9]{2}-' || true)
    [ -n "$_containers" ] && echo "$_containers" | xargs docker rm -f 2>/dev/null || true
    sleep 1
  fi
}

_kill_stale_consumers
rm -f "$PIDFILE"
(umask 077 && echo $$ > "$PIDFILE")

# Colors
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ts() {
  TZ="$RALPH_TZ" date +'%H:%M:%S'
}

# --- Background Resource Monitor ---
# Logs a one-line hardware snapshot every 20s, tagged [RESOURCES] for easy grep.
RESOURCE_MONITOR_PID=""
_start_resource_monitor() {
  (
    while true; do
      sleep 20
      load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
      # Memory: free -g on Linux, vm_stat + sysctl on macOS
      if command -v free &>/dev/null; then
        mem_info=$(free -g 2>/dev/null | awk '/^Mem:/ {printf "%dG/%dG(%d%%)", $3, $2, ($3/$2)*100}')
      else
        mem_total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
        mem_pages_active=$(vm_stat 2>/dev/null | awk '/Pages active:/ {gsub(/\./,""); print $3}')
        mem_page_size=$(vm_stat 2>/dev/null | awk -F'page size of ' '/page size/ {gsub(/[^0-9]/,"",$2); print $2}')
        if [ -n "$mem_total_bytes" ] && [ "$mem_total_bytes" -gt 0 ] && [ -n "$mem_pages_active" ] && [ -n "$mem_page_size" ]; then
          mem_used_gb=$(( (mem_pages_active * mem_page_size) / 1073741824 ))
          mem_total_gb=$(( mem_total_bytes / 1073741824 ))
          mem_pct=$(( (mem_pages_active * mem_page_size * 100) / mem_total_bytes ))
          mem_info="${mem_used_gb}G/${mem_total_gb}G(${mem_pct}%)"
        else
          mem_info="n/a"
        fi
      fi
      active_containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^r-[0-9]{2}-' || echo 0)
      container_stats=$(docker stats --no-stream --format '{{.Name}}={{.CPUPerc}}/{{.MemUsage}}' 2>/dev/null \
        | grep -E '^r-[0-9]{2}-' \
        | sed -E 's/r-0?/W/' \
        | tr '\n' ' ')
      echo -e "$(ts) ${DIM}[RESOURCES] load=$load ram=$mem_info containers=$active_containers $container_stats${RESET}"
    done
  ) &
  RESOURCE_MONITOR_PID=$!
}

_stop_resource_monitor() {
  if [ -n "$RESOURCE_MONITOR_PID" ] && kill -0 "$RESOURCE_MONITOR_PID" 2>/dev/null; then
    kill "$RESOURCE_MONITOR_PID" 2>/dev/null || true
    wait "$RESOURCE_MONITOR_PID" 2>/dev/null || true
  fi
}

# --- Clone/Update Repos ---

# Infer queue repo URL from the script's own git remote
if [ -z "$QUEUE_REPO" ]; then
  QUEUE_REPO=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)
  if [ -z "$QUEUE_REPO" ]; then
    echo "Error: could not infer queue repo URL. Pass --queue-repo explicitly."
    exit 1
  fi
fi

echo -e "$(ts) ${BOLD}Setting up consumer environment...${RESET}"

# Queue repo — bare clone for fast fetch/push, with a working tree checkout
if [ -d "$QUEUE_DIR/.git" ]; then
  echo -e "$(ts) ${DIM}Updating queue repo...${RESET}"
  git -C "$QUEUE_DIR" fetch origin main --quiet --force
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet
else
  echo -e "$(ts) ${DIM}Cloning queue repo...${RESET}"
  git clone "$QUEUE_REPO" "$QUEUE_DIR" --quiet
fi

# Set git identity for queue repo commits (claims, reverts, done/archive)
git -C "$QUEUE_DIR" config user.name "Ralph Wiggum"
git -C "$QUEUE_DIR" config user.email "ralph@opentabs.dev"

# Code repo — full clone for worktrees
if [ -d "$CODE_DIR/.git" ]; then
  echo -e "$(ts) ${DIM}Updating code repo...${RESET}"
  git -C "$CODE_DIR" fetch origin --quiet --prune
  git -C "$CODE_DIR" checkout main --quiet 2>/dev/null || git -C "$CODE_DIR" checkout -b main origin/main --quiet
  git -C "$CODE_DIR" reset --hard origin/main --quiet
else
  echo -e "$(ts) ${DIM}Cloning code repo...${RESET}"
  git clone "$CODE_REPO" "$CODE_DIR" --quiet
fi

# Set git identity for all consumer commits (auto-save, worktree branches)
git -C "$CODE_DIR" config user.name "Ralph Wiggum"
git -C "$CODE_DIR" config user.email "ralph@opentabs.dev"

# --- Docker Check (if using Docker) ---

DOCKER_IMAGE="ralph-worker:latest"
CONTAINER_PREFIX="r"

if [ "$USE_DOCKER" = true ]; then
  if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed. Use --no-docker or install Docker."
    exit 1
  fi
  if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running."
    exit 1
  fi
  if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo "Error: Docker image '$DOCKER_IMAGE' not found."
    echo "Build it: docker build -t ralph-worker -f <path-to-Dockerfile> ."
    exit 1
  fi
fi

# --- Worker Tracking ---

declare -a WORKER_PIDS=()
declare -a WORKER_CONTAINERS=()
declare -a WORKER_PRDS=()        # PRD basename (e.g., prd-..~running.json)
declare -a WORKER_WORKTREES=()
declare -a WORKER_BRANCHES=()
declare -a WORKER_SLUGS=()
declare -a WORKER_TAGS=()

for (( s=0; s<MAX_WORKERS; s++ )); do
  WORKER_PIDS[$s]=""
  WORKER_CONTAINERS[$s]=""
  WORKER_PRDS[$s]=""
  WORKER_WORKTREES[$s]=""
  WORKER_BRANCHES[$s]=""
  WORKER_SLUGS[$s]=""
  WORKER_TAGS[$s]=""
done

# Highest slot index ever initialized. reap_workers and cleanup iterate
# 0..SLOT_HIGH_WATER so that scale-down doesn't orphan active workers.
SLOT_HIGH_WATER=$((MAX_WORKERS - 1))

# --- Config File & Hot Reload ---
# Write current config so it can be edited and reloaded via SIGHUP.

_write_config() {
  (umask 077 && cat > "$CONFIG_FILE" <<EOF
# Ralph consumer config — edit and send SIGHUP to reload.
#   kill -HUP \$(cat ~/.ralph-consumer/.consumer.pid)
workers=$MAX_WORKERS
EOF
  )
}

_write_config

# SIGHUP handler — re-read MAX_WORKERS from config file.
# Scale-up: initialize new empty slots immediately.
# Scale-down: lower the cap; active workers in higher slots drain naturally.
_reload_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "$(ts) ${YELLOW}[SIGHUP] Config file not found: $CONFIG_FILE${RESET}"
    return
  fi

  local new_workers
  new_workers=$(grep -E '^workers=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')

  if [ -z "$new_workers" ] || ! [[ "$new_workers" =~ ^[0-9]+$ ]] || [ "$new_workers" -lt 1 ]; then
    echo -e "$(ts) ${YELLOW}[SIGHUP] Invalid workers value in $CONFIG_FILE. Ignoring.${RESET}"
    return
  fi

  local old_workers=$MAX_WORKERS
  MAX_WORKERS=$new_workers

  if [ "$MAX_WORKERS" -gt "$old_workers" ]; then
    # Scale up: initialize new empty slots
    for (( s=old_workers; s<MAX_WORKERS; s++ )); do
      WORKER_PIDS[$s]=""
      WORKER_CONTAINERS[$s]=""
      WORKER_PRDS[$s]=""
      WORKER_WORKTREES[$s]=""
      WORKER_BRANCHES[$s]=""
      WORKER_SLUGS[$s]=""
      WORKER_TAGS[$s]=""
    done
    SLOT_HIGH_WATER=$(( MAX_WORKERS - 1 ))
    echo -e "$(ts) ${GREEN}[SIGHUP] Scaled UP: $old_workers → $MAX_WORKERS workers${RESET}"
  elif [ "$MAX_WORKERS" -lt "$old_workers" ]; then
    # Scale down: just lower the cap. Active workers in slots >= MAX_WORKERS
    # continue running and are reaped normally. No new work is dispatched to them.
    echo -e "$(ts) ${GREEN}[SIGHUP] Scaled DOWN: $old_workers → $MAX_WORKERS workers (active workers will drain)${RESET}"
  else
    echo -e "$(ts) ${DIM}[SIGHUP] Workers unchanged: $MAX_WORKERS${RESET}"
  fi
}

trap _reload_config HUP

# --- Helper Functions ---

find_free_slot() {
  for (( s=0; s<MAX_WORKERS; s++ )); do
    if [ -z "${WORKER_PIDS[$s]}" ]; then
      echo "$s"
      return
    fi
  done
  echo ""
}

count_active_workers() {
  local count=0
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    [ -n "${WORKER_PIDS[$s]}" ] && count=$((count + 1))
  done
  echo "$count"
}

# Extract slug from PRD filename.
# prd-2026-02-17-143000-improve-sdk.json → 2026-02-17-143000-improve-sdk
prd_slug() {
  local base
  base=$(basename "$1" .json)
  base="${base/~running/}"
  base="${base/~done/}"
  base="${base/~draft/}"
  echo "${base#prd-}"
}

# Extract short objective from PRD filename.
# prd-2026-02-17-143000-improve-sdk.json → improve-sdk
prd_objective() {
  local slug
  slug=$(prd_slug "$1")
  echo "${slug:18}"
}

# Find ready PRDs in the queue directory (sorted oldest first).
find_ready_prds() {
  find "$QUEUE_DIR" -maxdepth 1 -name 'prd-*.json' -type f \
    ! -name '*~draft*' \
    ! -name '*~running*' \
    ! -name '*~done*' \
    2>/dev/null | sort
}

has_ready_prds() {
  local count
  count=$(find "$QUEUE_DIR" -maxdepth 1 -name 'prd-*.json' -type f \
    ! -name '*~draft*' \
    ! -name '*~running*' \
    ! -name '*~done*' \
    2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

# --- Atomic Claim ---
# Claims a PRD by renaming it to ~running and pushing to the remote.
# Returns 0 on success (PRD is now ours), 1 on failure (someone else claimed it).
#
# This is the critical atomicity mechanism:
#   1. Fetch latest queue state
#   2. Check the PRD still exists (not claimed by another worker)
#   3. Rename to ~running
#   4. Commit with worker identity
#   5. Push — if this succeeds, we own the PRD
#   6. If push fails (non-fast-forward), another worker modified the queue
#      concurrently. We hard-reset and return failure.
claim_prd() {
  local prd_basename="$1"
  local prd_path="$QUEUE_DIR/$prd_basename"

  # Fetch latest state
  git -C "$QUEUE_DIR" fetch origin main --quiet

  # Hard reset to remote HEAD — we never have local-only commits in the queue
  # (we push immediately after each claim/done transition)
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet

  # Verify the PRD still exists and is still ready (not claimed by another worker)
  if [ ! -f "$prd_path" ]; then
    return 1
  fi

  # Rename to ~running
  local running_basename="${prd_basename%.json}~running.json"
  git -C "$QUEUE_DIR" mv "$prd_basename" "$running_basename"

  # Commit with worker identity
  git -C "$QUEUE_DIR" commit -m "claim: $prd_basename [worker=$WORKER_ID]" --quiet

  # Push — atomic gate
  if git -C "$QUEUE_DIR" push origin main --quiet 2>/dev/null; then
    echo "$running_basename"
    return 0
  fi

  # Push failed — another worker modified the queue. Reset and fail.
  git -C "$QUEUE_DIR" fetch origin main --quiet
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet
  return 1
}

# Mark a PRD as ~done and push to remote.
# Uses the same push-or-retry pattern as the producer.
#
# Arguments:
#   $1 — running PRD basename (e.g., prd-..~running.json)
#   $2 — path to the updated PRD file from the worktree (with passes: true fields)
#   $3 — path to the progress file from the worktree (optional, empty string if none)
#
# The updated PRD and progress files are passed as separate paths because
# git fetch + reset would overwrite files already copied into $QUEUE_DIR.
mark_done_and_push() {
  local running_basename="$1"
  local updated_prd_path="$2"
  local updated_progress_path="$3"

  # Fetch latest (other workers may have claimed/done other PRDs)
  git -C "$QUEUE_DIR" fetch origin main --quiet

  # Reset to remote HEAD — clean slate
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet

  # Verify the ~running file exists on remote
  if [ ! -f "$QUEUE_DIR/$running_basename" ]; then
    echo "Warning: ~running PRD not found in queue: $running_basename"
    return 1
  fi

  # Overwrite the ~running file with the worker's updated version (passes fields)
  if [ -n "$updated_prd_path" ] && [ -f "$updated_prd_path" ]; then
    cp "$updated_prd_path" "$QUEUE_DIR/$running_basename"
  fi

  # Copy progress file into the queue repo
  if [ -n "$updated_progress_path" ] && [ -f "$updated_progress_path" ]; then
    cp "$updated_progress_path" "$QUEUE_DIR/"
  fi

  # Rename to ~done
  local done_basename="${running_basename/~running/~done}"
  git -C "$QUEUE_DIR" mv "$running_basename" "$done_basename"

  # Stage the updated content and any progress file
  git -C "$QUEUE_DIR" add -A
  git -C "$QUEUE_DIR" commit -m "done: $done_basename [worker=$WORKER_ID]" --quiet

  # Push with retry
  local max_retries=5
  for attempt in $(seq 1 $max_retries); do
    if git -C "$QUEUE_DIR" push origin main --quiet 2>/dev/null; then
      return 0
    fi
    git -C "$QUEUE_DIR" fetch origin main --quiet
    git -C "$QUEUE_DIR" rebase origin/main --quiet 2>/dev/null || {
      git -C "$QUEUE_DIR" rebase --abort 2>/dev/null || true
      git -C "$QUEUE_DIR" reset --hard origin/main --quiet
      # Re-apply: copy updated files, rename, commit
      if [ -f "$QUEUE_DIR/$running_basename" ]; then
        [ -n "$updated_prd_path" ] && [ -f "$updated_prd_path" ] && cp "$updated_prd_path" "$QUEUE_DIR/$running_basename"
        [ -n "$updated_progress_path" ] && [ -f "$updated_progress_path" ] && cp "$updated_progress_path" "$QUEUE_DIR/"
        git -C "$QUEUE_DIR" mv "$running_basename" "$done_basename"
        git -C "$QUEUE_DIR" add -A
        git -C "$QUEUE_DIR" commit -m "done: $done_basename [worker=$WORKER_ID]" --quiet
      fi
    }
    sleep 1
  done

  echo "Warning: could not push ~done state after $max_retries attempts."
  return 1
}

# Archive a ~done PRD — move to archive/ and push.
# This is a non-critical operation. If it fails, the ~done file stays in the
# queue root — it won't be claimed again (it has ~done suffix).
archive_and_push() {
  local done_basename="$1"
  local slug
  slug=$(prd_slug "$done_basename")

  # Fetch latest first — mark_done_and_push just pushed, but other consumers
  # may have pushed between then and now.
  git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || return 1
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || return 1

  # Verify the ~done file exists
  if [ ! -f "$QUEUE_DIR/$done_basename" ]; then
    # Already archived by someone else, or mark_done failed — nothing to do
    return 0
  fi

  local archive_dir="$QUEUE_DIR/archive/${done_basename%.json}"
  mkdir -p "$archive_dir"

  # Move PRD into archive
  mv "$QUEUE_DIR/$done_basename" "$archive_dir/"

  # Move progress file if it exists
  local progress_basename="progress-${slug}.txt"
  if [ -f "$QUEUE_DIR/$progress_basename" ]; then
    mv "$QUEUE_DIR/$progress_basename" "$archive_dir/"
  fi

  git -C "$QUEUE_DIR" add -A
  git -C "$QUEUE_DIR" commit -m "archive: $done_basename" --quiet 2>/dev/null || return 0

  # Push with retry
  local max_retries=3
  for attempt in $(seq 1 $max_retries); do
    if git -C "$QUEUE_DIR" push origin main --quiet 2>/dev/null; then
      return 0
    fi
    git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || return 1
    git -C "$QUEUE_DIR" rebase origin/main --quiet 2>/dev/null || {
      git -C "$QUEUE_DIR" rebase --abort 2>/dev/null || true
      return 1
    }
    sleep 1
  done
  return 1
}

# Robustly remove a git worktree directory.
remove_worktree() {
  local wt="$1"
  [ -z "$wt" ] || [ ! -d "$wt" ] && return 0
  git -C "$CODE_DIR" worktree remove --force "$wt" >/dev/null 2>&1 && return 0
  rm -rf "$wt" 2>/dev/null && { git -C "$CODE_DIR" worktree prune 2>/dev/null || true; return 0; }
  sleep 2
  rm -rf "$wt" 2>/dev/null || true
  git -C "$CODE_DIR" worktree prune 2>/dev/null || true
}

# --- Worker Setup (runs in main loop, single-threaded) ---
# Creates worktree and copies files. Called from dispatch_prd before
# backgrounding the agent. This ensures all git operations on $CODE_DIR
# and $QUEUE_DIR are serialized in the main loop.

setup_worktree() {
  local slug="$1"
  local running_basename="$2"
  local tag="$3"

  local branch_name="ralph-$slug"
  local worktree_dir="$WORKTREE_BASE/$slug"

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Preparing worktree...${RESET}"

  # Update code repo to latest main
  git -C "$CODE_DIR" fetch origin --quiet

  # Clean up stale worktree/branch
  if [ -d "$worktree_dir" ]; then
    remove_worktree "$worktree_dir"
  fi
  if git -C "$CODE_DIR" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    git -C "$CODE_DIR" branch -D "$branch_name" 2>/dev/null || true
  fi

  # Create worktree from latest main
  if ! git -C "$CODE_DIR" worktree add "$worktree_dir" -b "$branch_name" origin/main >/dev/null 2>&1; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Failed to create worktree. Aborting.${RESET}"
    return 1
  fi

  # Copy PRD into worktree's .ralph/ directory
  mkdir -p "$worktree_dir/.ralph"
  cp "$QUEUE_DIR/$running_basename" "$worktree_dir/.ralph/"

  # Copy progress file if it exists
  local progress_basename="progress-${slug}.txt"
  if [ -f "$QUEUE_DIR/$progress_basename" ]; then
    cp "$QUEUE_DIR/$progress_basename" "$worktree_dir/.ralph/"
  fi

  # Copy RALPH.md (agent instructions) from the code repo into the worktree
  if [ -f "$CODE_DIR/.ralph/RALPH.md" ]; then
    cp "$CODE_DIR/.ralph/RALPH.md" "$worktree_dir/.ralph/"
  fi

  # Copy worker.sh from code repo
  if [ -f "$CODE_DIR/.ralph/worker.sh" ]; then
    cp "$CODE_DIR/.ralph/worker.sh" "$worktree_dir/.ralph/worker.sh"
  fi

  return 0
}

# --- Worker Execution (runs in background subshell) ---
# Installs deps, builds, runs agent, pushes branch.
#
# IMPORTANT: This function must NOT touch $QUEUE_DIR or $CODE_DIR's git index.
# Multiple workers run concurrently as background subshells. Each worker
# operates only on its own worktree (which has its own .git file pointing
# to an isolated worktree entry). Queue repo updates happen in reap_workers.

run_worker() {
  local slot="$1"
  local worktree_dir="$2"
  local running_basename="$3"
  local branch_name="$4"
  local tag="$5"
  local slug="$6"

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Installing dependencies + building...${RESET}"

  # Install and build, then run the agent
  if [ "$USE_DOCKER" = true ]; then
    _run_worker_docker "$slot" "$worktree_dir" "$running_basename" "$branch_name" "$tag" "$slug"
  else
    _run_worker_host "$slot" "$worktree_dir" "$running_basename" "$branch_name" "$tag" "$slug"
  fi
  local exit_code=$?

  # Push the branch to code repo remote.
  # Safe — each worker pushes to its own uniquely-named branch (no other writer).
  # Uses plain push (not --force-with-lease) because this is the first push of a
  # new branch — there's no remote tracking ref for force-with-lease to compare.
  #
  # A sentinel file ($worktree_dir/.ralph/.push-ok) signals to reap_workers that
  # the push succeeded. Without it, reap_workers preserves the worktree and branch
  # so the commits aren't lost.
  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Worker finished (exit $exit_code). Pushing branch...${RESET}"
  local commit_count
  commit_count=$(git -C "$worktree_dir" rev-list --count "origin/main..$branch_name" 2>/dev/null || echo "0")
  if [ "$commit_count" -gt 0 ]; then
    local push_attempts=3
    for pa in $(seq 1 $push_attempts); do
      if git -C "$worktree_dir" push origin "$branch_name" 2>&1; then
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Branch pushed: $branch_name ($commit_count commits)${RESET}"
        touch "$worktree_dir/.ralph/.push-ok"
        break
      fi
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push attempt $pa/$push_attempts failed. Retrying...${RESET}"
      sleep 2
    done
    if [ ! -f "$worktree_dir/.ralph/.push-ok" ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Failed to push branch after $push_attempts attempts. Worktree preserved at: $worktree_dir${RESET}"
    fi
  else
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}No commits to push.${RESET}"
    touch "$worktree_dir/.ralph/.push-ok"
  fi

  return $exit_code
}

# Run worker inside Docker container.
_run_worker_docker() {
  local slot="$1"
  local worktree_dir="$2"
  local running_basename="$3"
  local branch_name="$4"
  local tag="$5"
  local slug="$6"
  local objective="${slug:18}"
  local container_name
  printf -v container_name '%s-%02d-%s' "$CONTAINER_PREFIX" "$slot" "$objective"

  # Clean up leftover container
  docker rm -f "$container_name" 2>/dev/null || true

  # Build Docker args
  local -a DOCKER_COMMON=()
  # No CPU or memory cap — let the OS scheduler handle sharing.
  # 62 GB RAM is more than enough for 4 concurrent workers.
  DOCKER_COMMON+=(--init --ipc=host --shm-size=2g)
  DOCKER_COMMON+=(--user "$(id -u):$(id -g)")
  DOCKER_COMMON+=(-e "HOME=/tmp/worker")
  DOCKER_COMMON+=(-v "$worktree_dir:$worktree_dir")
  DOCKER_COMMON+=(-v "$CODE_DIR/.git:$CODE_DIR/.git")
  DOCKER_COMMON+=(--network host)

  if [ -f "$HOME/.npmrc" ]; then
    DOCKER_COMMON+=(-v "$HOME/.npmrc:/tmp/staging/.npmrc:ro")
  fi
  if [ -f "$HOME/.claude/settings.json" ]; then
    DOCKER_COMMON+=(-v "$HOME/.claude/settings.json:/tmp/staging/claude-settings.json:ro")
  fi

  local CONTAINER_INIT
  CONTAINER_INIT="mkdir -p /tmp/worker/.claude"
  CONTAINER_INIT="$CONTAINER_INIT && cp /tmp/staging/.npmrc /tmp/worker/.npmrc 2>/dev/null"
  CONTAINER_INIT="$CONTAINER_INIT; cp /tmp/staging/claude-settings.json /tmp/worker/.claude/settings.json 2>/dev/null"
  CONTAINER_INIT="$CONTAINER_INIT; true"

  # Setup: install + build
  local setup_script="cd $worktree_dir && npm install 2>&1 | tail -1 && npm run build 2>&1 | tail -3"
  if [ -f "$worktree_dir/plugins/e2e-test/package.json" ]; then
    setup_script="$setup_script && cd $worktree_dir/plugins/e2e-test && npm install 2>&1 | tail -1 && OPENTABS_CONFIG_DIR=/tmp/opentabs-plugin-config npm run build 2>&1 | tail -1"
  fi

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Running setup in Docker...${RESET}"
  docker run --rm "${DOCKER_COMMON[@]}" \
    -w "$worktree_dir" \
    "$DOCKER_IMAGE" \
    "bash -c '$CONTAINER_INIT && $setup_script'" \
    2>&1 | while IFS= read -r line; do
      echo -e "$(ts) $line"
    done
  local setup_exit=${PIPESTATUS[0]}
  if [ "$setup_exit" -ne 0 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Setup failed in Docker (exit $setup_exit).${RESET}"
    return 1
  fi

  # Environment variables for the worker
  local -a DOCKER_ENV_ARGS=()
  DOCKER_ENV_ARGS+=(-e "WORKER_TOOL=$TOOL")
  DOCKER_ENV_ARGS+=(-e "WORKER_PRD_FILE=$running_basename")
  DOCKER_ENV_ARGS+=(-e "WORKER_RESULT_FILE=/tmp/worker-result.txt")
  DOCKER_ENV_ARGS+=(-e "WORKER_WORKTREE_DIR=$worktree_dir")
  DOCKER_ENV_ARGS+=(-e "CLAUDECODE=")
  DOCKER_ENV_ARGS+=(-e "CI=1")
  DOCKER_ENV_ARGS+=(-e "PW_WORKERS=20")
  DOCKER_ENV_ARGS+=(-e "WORKER_TAG=$tag")
  DOCKER_ENV_ARGS+=(-e "WORKER_MODEL_SONNET=${WORKER_MODEL_SONNET:-claude-sonnet}")
  DOCKER_ENV_ARGS+=(-e "WORKER_MODEL_OPUS=${WORKER_MODEL_OPUS:-claude-opus}")

  # Forward Anthropic env vars
  for var in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_AUTH_MODEL ANTHROPIC_API_KEY; do
    local val
    val=$(printenv "$var" 2>/dev/null) || true
    [ -n "$val" ] && DOCKER_ENV_ARGS+=(-e "$var=$val")
  done

  # Forward env vars from Claude settings
  if [ -f "$HOME/.claude/settings.json" ]; then
    local settings_envs
    settings_envs=$(jq -r '.env // {} | to_entries[] | .key + "=" + .value' "$HOME/.claude/settings.json" 2>/dev/null) || true
    if [ -n "$settings_envs" ]; then
      while IFS= read -r kv; do
        [ -z "$kv" ] && continue
        DOCKER_ENV_ARGS+=(-e "$kv")
      done <<< "$settings_envs"
    fi
  fi

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Starting Docker container: $container_name${RESET}"

  # Run the worker container — pipe output through timestamp prefixer.
  # Worker.sh handles its own [tag(a/n)] prefixing.
  docker run --rm \
    --name "$container_name" \
    "${DOCKER_COMMON[@]}" \
    "${DOCKER_ENV_ARGS[@]}" \
    -w "$worktree_dir" \
    "$DOCKER_IMAGE" \
    "$CONTAINER_INIT && bash $worktree_dir/.ralph/worker.sh" \
    2>&1 | while IFS= read -r line; do
      echo -e "$(ts) $line"
    done
  local worker_exit=${PIPESTATUS[0]}
  if [ "$worker_exit" -ne 0 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Worker container exited with error (exit $worker_exit).${RESET}"
    return 1
  fi

  return 0
}

# Run worker directly on host (--no-docker).
_run_worker_host() {
  local slot="$1"
  local worktree_dir="$2"
  local running_basename="$3"
  local branch_name="$4"
  local tag="$5"
  local slug="$6"

  # Install + build
  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Installing dependencies...${RESET}"
  (cd "$worktree_dir" && npm install 2>&1 | tail -1) || {
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}npm install failed.${RESET}"
    return 1
  }

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Building...${RESET}"
  (cd "$worktree_dir" && npm run build 2>&1 | tail -3) || {
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}npm run build failed.${RESET}"
    return 1
  }

  # Build e2e-test plugin if present
  if [ -f "$worktree_dir/plugins/e2e-test/package.json" ]; then
    (cd "$worktree_dir/plugins/e2e-test" && npm install 2>&1 | tail -1 && npm run build 2>&1 | tail -1) || true
  fi

  # Run worker.sh with env vars — pipe output through tag prefixer.
  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Running worker...${RESET}"
  WORKER_TOOL="$TOOL" \
  WORKER_PRD_FILE="$running_basename" \
  WORKER_RESULT_FILE="/tmp/worker-result-${slug}.txt" \
  WORKER_WORKTREE_DIR="$worktree_dir" \
  WORKER_TAG="$tag" \
  WORKER_MODEL_SONNET="${WORKER_MODEL_SONNET:-claude-sonnet}" \
  WORKER_MODEL_OPUS="${WORKER_MODEL_OPUS:-claude-opus}" \
  bash "$worktree_dir/.ralph/worker.sh" 2>&1 | while IFS= read -r line; do
    echo -e "$(ts) $line"
  done
  return ${PIPESTATUS[0]}
}

# --- Cleanup ---

cleanup() {
  echo ""
  echo -e "$(ts) ${YELLOW}Shutting down consumer...${RESET}"

  _stop_resource_monitor

  # Phase 1: Kill all workers and containers
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local pid="${WORKER_PIDS[$s]}"
    local container="${WORKER_CONTAINERS[$s]}"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi

    if [ -n "$container" ] && [ "$USE_DOCKER" = true ]; then
      docker kill "$container" 2>/dev/null || true
      docker rm -f "$container" 2>/dev/null || true
    fi
  done

  # Wait for all workers to exit after kill signals sent
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local pid="${WORKER_PIDS[$s]}"
    if [ -n "$pid" ]; then
      wait "$pid" 2>/dev/null || true
    fi
  done

  # Phase 2: Save uncommitted work in each worktree before cleanup.
  # Commit any dirty changes to the branch and push to remote so work is never lost.
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local wt="${WORKER_WORKTREES[$s]}"
    local br="${WORKER_BRANCHES[$s]}"
    local tag="${WORKER_TAGS[$s]}"

    if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$br" ]; then
      # Check for uncommitted changes
      local has_changes
      has_changes=$(git -C "$wt" status --porcelain 2>/dev/null | head -1)
      if [ -n "$has_changes" ]; then
        echo -e "$(ts) ${DIM}[${tag}] Saving uncommitted work...${RESET}"
        git -C "$wt" add -A 2>/dev/null || true
        git -C "$wt" commit -m "wip: auto-save on consumer shutdown [worker=$WORKER_ID]" --no-verify --quiet 2>/dev/null || true
      fi

      # Push branch to remote (with or without new commit — ensures all work is saved).
      # --no-verify: skip hooks intentionally during emergency shutdown to avoid blocking.
      # Fallback from --force-with-lease to plain push: if the remote branch was updated
      # by another process, force-with-lease fails. Plain push is acceptable because
      # each ralph-* branch has a single writer (the worker that owns it).
      local commit_count
      commit_count=$(git -C "$wt" rev-list --count "origin/main..$br" 2>/dev/null || echo "0")
      if [ "$commit_count" -gt 0 ]; then
        echo -e "$(ts) ${DIM}[${tag}] Pushing branch $br ($commit_count commits)...${RESET}"
        git -C "$wt" push origin "$br" --no-verify --force-with-lease 2>/dev/null || \
          git -C "$wt" push origin "$br" --no-verify 2>/dev/null || \
          echo -e "$(ts) ${YELLOW}[${tag}] Push failed — work preserved locally at: $wt${RESET}"
      fi
    fi
  done

  # Phase 3: Clean up worktrees and branches
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local wt="${WORKER_WORKTREES[$s]}"
    local br="${WORKER_BRANCHES[$s]}"

    if [ -n "$wt" ] && [ -d "$wt" ]; then
      remove_worktree "$wt"
    fi
    if [ -n "$br" ]; then
      git -C "$CODE_DIR" branch -D "$br" 2>/dev/null || true
    fi
  done

  # Phase 3: Revert all ~running PRDs back to ready in a single atomic commit.
  # Fetch latest state first so our commit applies cleanly on top of remote.
  local reverted_any=false
  git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || true
  git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local prd="${WORKER_PRDS[$s]}"
    if [ -n "$prd" ]; then
      local ready_basename="${prd/~running.json/.json}"
      if [ "$prd" != "$ready_basename" ] && [ -f "$QUEUE_DIR/$prd" ]; then
        git -C "$QUEUE_DIR" mv "$prd" "$ready_basename" 2>/dev/null || true
        reverted_any=true
        echo -e "$(ts) ${DIM}Reverted: $prd → $ready_basename${RESET}"
      fi
    fi
  done

  # Single commit + push for all reverts
  if [ "$reverted_any" = true ]; then
    git -C "$QUEUE_DIR" commit -m "revert: consumer shutdown [worker=$WORKER_ID]" --quiet 2>/dev/null || true
    # Push with retry (other consumers may be pushing concurrently)
    for attempt in 1 2 3; do
      if git -C "$QUEUE_DIR" push origin main --quiet 2>/dev/null; then
        break
      fi
      git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || break
      if ! git -C "$QUEUE_DIR" rebase origin/main --quiet 2>/dev/null; then
        # Rebase failed — reset and re-apply all renames from scratch
        git -C "$QUEUE_DIR" rebase --abort 2>/dev/null || true
        git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || break
        local re_applied=false
        for (( r=0; r<=SLOT_HIGH_WATER; r++ )); do
          local rprd="${WORKER_PRDS[$r]}"
          if [ -n "$rprd" ]; then
            local rready="${rprd/~running.json/.json}"
            if [ "$rprd" != "$rready" ] && [ -f "$QUEUE_DIR/$rprd" ]; then
              git -C "$QUEUE_DIR" mv "$rprd" "$rready" 2>/dev/null || true
              re_applied=true
            fi
          fi
        done
        if [ "$re_applied" = true ]; then
          git -C "$QUEUE_DIR" commit -m "revert: consumer shutdown [worker=$WORKER_ID]" --quiet 2>/dev/null || break
        else
          break
        fi
      fi
    done
  fi

  git -C "$CODE_DIR" worktree prune 2>/dev/null || true
  rm -f "$PIDFILE"
  echo -e "$(ts) ${GREEN}Consumer stopped.${RESET}"
}

trap cleanup EXIT

# --- Reap Workers ---
# Check for completed worker subshells, perform post-processing.
# This runs in the main loop (single-threaded) so queue repo operations
# are serialized — no concurrent git index corruption.

reap_workers() {
  for (( s=0; s<=SLOT_HIGH_WATER; s++ )); do
    local pid="${WORKER_PIDS[$s]}"
    [ -z "$pid" ] && continue

    # Check if the background process is still running
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi

    # Process exited — collect exit code
    wait "$pid" 2>/dev/null
    local exit_code=$?

    local tag="${WORKER_TAGS[$s]}"
    local running_basename="${WORKER_PRDS[$s]}"
    local worktree_dir="${WORKER_WORKTREES[$s]}"
    local branch_name="${WORKER_BRANCHES[$s]}"
    local slug="${WORKER_SLUGS[$s]}"

    if [ "$exit_code" -eq 0 ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Worker completed successfully.${RESET}"
    else
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Worker finished with errors (exit $exit_code).${RESET}"
    fi

    # --- Post-processing (queue repo operations, serialized here) ---

    # Locate updated files in the worktree (passed to mark_done_and_push)
    local updated_prd=""
    local updated_progress=""
    local progress_basename="progress-${slug}.txt"
    if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
      [ -f "$worktree_dir/.ralph/$running_basename" ] && updated_prd="$worktree_dir/.ralph/$running_basename"
      [ -f "$worktree_dir/.ralph/$progress_basename" ] && updated_progress="$worktree_dir/.ralph/$progress_basename"
    fi

    # Mark PRD as ~done in queue and push (includes syncing updated files)
    if [ -n "$running_basename" ]; then
      mark_done_and_push "$running_basename" "$updated_prd" "$updated_progress"
      local done_basename="${running_basename/~running/~done}"
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Marked done: $done_basename${RESET}"

      # Archive
      archive_and_push "$done_basename"
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Archived.${RESET}"
    fi

    # Cleanup worktree and branch — only if push succeeded (sentinel exists).
    # If push failed, preserve the worktree and branch so commits aren't lost.
    local push_ok=false
    if [ -n "$worktree_dir" ] && [ -f "$worktree_dir/.ralph/.push-ok" ]; then
      push_ok=true
    fi

    if [ "$push_ok" = true ]; then
      if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
        remove_worktree "$worktree_dir"
      fi
      if [ -n "$branch_name" ]; then
        git -C "$CODE_DIR" branch -D "$branch_name" 2>/dev/null || true
      fi
    else
      # Push failed — preserve worktree for manual recovery
      local commit_count
      commit_count=$(git -C "$CODE_DIR" rev-list --count "origin/main..$branch_name" 2>/dev/null || echo "0")
      if [ "$commit_count" -gt 0 ]; then
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Push failed — preserving worktree and branch for recovery:${RESET}"
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}  Worktree: $worktree_dir${RESET}"
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}  Branch:   $branch_name${RESET}"
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}  To push manually: git -C $worktree_dir push origin $branch_name${RESET}"
      else
        # No commits to preserve — clean up normally
        if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
          remove_worktree "$worktree_dir"
        fi
        if [ -n "$branch_name" ]; then
          git -C "$CODE_DIR" branch -D "$branch_name" 2>/dev/null || true
        fi
      fi
    fi

    # Free the slot
    WORKER_PIDS[$s]=""
    WORKER_CONTAINERS[$s]=""
    WORKER_PRDS[$s]=""
    WORKER_WORKTREES[$s]=""
    WORKER_BRANCHES[$s]=""
    WORKER_SLUGS[$s]=""
    WORKER_TAGS[$s]=""
  done
}

# --- Dispatch ---

dispatch_prd() {
  local prd_basename="$1"
  local slot="$2"

  local slug
  slug=$(prd_slug "$prd_basename")
  local objective
  objective=$(prd_objective "$prd_basename")
  local tag="W${slot}:${objective:0:20}"

  echo ""
  echo -e "$(ts) ${BOLD}┌───────────────────────────────────────────────────────────┐${RESET}"
  echo -e "$(ts) ${BOLD}│  [${tag}] Claiming: $prd_basename${RESET}"
  echo -e "$(ts) ${BOLD}└───────────────────────────────────────────────────────────┘${RESET}"

  # Atomic claim via git push
  local running_basename=""
  if ! running_basename=$(claim_prd "$prd_basename") || [ -z "$running_basename" ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Claim failed (another worker got it first). Skipping.${RESET}"
    return 1
  fi

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Claimed: $running_basename${RESET}"

  # Extract primary model from PRD (first story's model field)
  local prd_model=""
  if [ -f "$QUEUE_DIR/$running_basename" ]; then
    prd_model=$(python3 -c "
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  stories=d.get('userStories',[])
  if stories: print(stories[0].get('model',''))
except: pass" "$QUEUE_DIR/$running_basename" 2>/dev/null)
  fi
  # Short label: opus, sonnet, etc.
  case "$prd_model" in
    *opus*)   prd_model="opus" ;;
    *sonnet*) prd_model="sonnet" ;;
    *haiku*)  prd_model="haiku" ;;
    "")       prd_model="?" ;;
  esac
  tag="W${slot}:${objective:0:20}:${prd_model}"

  local branch_name="ralph-$slug"
  local worktree_dir="$WORKTREE_BASE/$slug"

  # Setup worktree in main loop (serialized — no concurrent git ops)
  if ! setup_worktree "$slug" "$running_basename" "$tag"; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Worktree setup failed. Reverting claim.${RESET}"
    # Revert: fetch latest, rename ~running back to ready, push with retry
    local ready_basename="${running_basename/~running.json/.json}"
    for revert_attempt in 1 2 3; do
      git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || true
      git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || true
      if [ ! -f "$QUEUE_DIR/$running_basename" ]; then
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}~running file gone from remote. Cannot revert.${RESET}"
        break
      fi
      git -C "$QUEUE_DIR" mv "$running_basename" "$ready_basename" 2>/dev/null || break
      git -C "$QUEUE_DIR" commit -m "revert: $running_basename (setup failed) [worker=$WORKER_ID]" --quiet 2>/dev/null || break
      if git -C "$QUEUE_DIR" push origin main --quiet 2>/dev/null; then
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Claim reverted successfully.${RESET}"
        break
      fi
    done
    return 1
  fi

  # Launch worker in background subshell (only agent execution + branch push)
  run_worker "$slot" "$worktree_dir" "$running_basename" "$branch_name" "$tag" "$slug" &
  local worker_pid=$!

  WORKER_PIDS[$slot]="$worker_pid"
  printf -v _cname '%s-%02d-%s' "$CONTAINER_PREFIX" "$slot" "$objective"
  WORKER_CONTAINERS[$slot]="$_cname"
  WORKER_PRDS[$slot]="$running_basename"
  WORKER_WORKTREES[$slot]="$worktree_dir"
  WORKER_BRANCHES[$slot]="$branch_name"
  WORKER_SLUGS[$slot]="$slug"
  WORKER_TAGS[$slot]="$tag"

  return 0
}

# --- Main ---

echo ""
echo -e "$(ts) ${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "$(ts) ${BOLD}║  Ralph Consumer — Distributed PRD Worker                 ║${RESET}"
echo -e "$(ts) ${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "$(ts)   Worker ID:  ${CYAN}${WORKER_ID}${RESET}"
echo -e "$(ts)   Tool:       ${CYAN}${TOOL}${RESET}"
[ -n "$MODEL" ] && echo -e "$(ts)   Model:      ${CYAN}${MODEL}${RESET}"
echo -e "$(ts)   Workers:    ${CYAN}${MAX_WORKERS}${RESET}"
echo -e "$(ts)   Docker:     ${CYAN}$([ "$USE_DOCKER" = true ] && echo "yes ($DOCKER_IMAGE)" || echo "no (host-native)")${RESET}"
echo -e "$(ts)   Mode:       ${CYAN}$([ "$ONCE" = true ] && echo "single batch" || echo "daemon (poll every ${POLL_INTERVAL}s)")${RESET}"
echo -e "$(ts)   Queue:      ${CYAN}${QUEUE_REPO}${RESET}"
echo -e "$(ts)   Code:       ${CYAN}${CODE_REPO}${RESET}"
echo -e "$(ts)   Base dir:   ${CYAN}${CONSUMER_BASE}${RESET}"
echo -e "$(ts)   Logs:       ${CYAN}${LOG_DIR}/latest.log${RESET}"
echo ""

_start_resource_monitor

DISPATCHED_ANY=false

while true; do
  # Reap completed workers
  reap_workers

  ACTIVE=$(count_active_workers)

  # In --once mode, exit when all workers done and no more ready PRDs
  if [ "$ONCE" = true ] && [ "$DISPATCHED_ANY" = true ] && [ "$ACTIVE" -eq 0 ]; then
    # Fetch latest before checking — a new PRD may have been published
    git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || true
    git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || true
    if ! has_ready_prds; then
      echo ""
      echo -e "$(ts) ${DIM}--once mode: all PRDs complete. Exiting.${RESET}"
      exit 0
    fi
  fi

  # Dispatch new PRDs to free slots (check if any slot 0..MAX_WORKERS-1 is free)
  if [ -n "$(find_free_slot)" ]; then
    # Fetch latest queue state before looking for PRDs
    git -C "$QUEUE_DIR" fetch origin main --quiet 2>/dev/null || true
    git -C "$QUEUE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

    READY_PRDS=$(find_ready_prds)

    if [ -n "$READY_PRDS" ]; then
      while IFS= read -r prd_path; do
        [ -z "$prd_path" ] && continue

        SLOT=$(find_free_slot)
        [ -z "$SLOT" ] && break

        prd_basename=$(basename "$prd_path")
        dispatch_prd "$prd_basename" "$SLOT" && DISPATCHED_ANY=true || true
      done <<< "$READY_PRDS"
    fi
  fi

  # In --once mode with nothing dispatched, exit
  if [ "$ONCE" = true ] && [ "$DISPATCHED_ANY" = false ]; then
    ACTIVE=$(count_active_workers)
    if [ "$ACTIVE" -eq 0 ]; then
      echo -e "$(ts) ${DIM}No PRD files found. Exiting (--once mode).${RESET}"
      exit 0
    fi
  fi

  sleep "$POLL_INTERVAL"
done
