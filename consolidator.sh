#!/bin/bash
# Consolidator — merges completed ralph-* branches into main on the code repo.
#
# Usage:
#   ./consolidator.sh --code-repo <url-or-path> [options]
#
# Options:
#   --code-repo <url>    Git URL or local path for the opentabs code repo (REQUIRED)
#   --once               Merge all available branches and exit (don't poll)
#   --poll <n>           Poll interval in seconds (default: 30)
#   --dry-run            Show what would be merged without doing it
#   --model <model>      AI model for conflict resolution (default: claude-opus)
#
# The consolidator:
#   1. Fetches all remote branches matching ralph-*
#   2. Attempts to merge each into main (oldest first, by branch creation time)
#   3. If a merge conflicts, invokes AI (Claude) to resolve; falls back to breadcrumb if AI fails
#   4. Pushes main to remote after each successful merge
#
# This is the single serialization point for code merges. Only one consolidator
# should run at a time (enforced by a lock file). Workers push branches to
# the remote; the consolidator merges them into main.

# NOTE: set -e is intentionally NOT used.

# --- Ensure user-local npm binaries are on PATH ---
# Claude CLI may be installed in ~/.npm-global/bin or similar user-local prefix.
# Non-login shells (cron, systemd, tmux new-session) don't source ~/.bashrc,
# so we add common user-local bin paths explicitly.
for _p in "$HOME/.npm-global/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$_p" ] && case ":$PATH:" in *":$_p:"*) ;; *) PATH="$_p:$PATH" ;; esac
done
unset _p
export PATH

# --- Argument Parsing ---

CODE_REPO=""
ONCE=false
POLL_INTERVAL=30
DRY_RUN=false
CONSOLIDATOR_MODEL="claude-opus"

while [[ $# -gt 0 ]]; do
  case $1 in
    --code-repo)   CODE_REPO="$2";    shift 2 ;;
    --code-repo=*) CODE_REPO="${1#*=}"; shift ;;
    --once)        ONCE=true;          shift ;;
    --poll)        POLL_INTERVAL="$2"; shift 2 ;;
    --poll=*)      POLL_INTERVAL="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=true;       shift ;;
    --model)       CONSOLIDATOR_MODEL="$2"; shift 2 ;;
    --model=*)     CONSOLIDATOR_MODEL="${1#*=}"; shift ;;
    -*)            echo "Warning: unknown option: $1"; shift ;;
    *)             shift ;;
  esac
done

if [ -z "$CODE_REPO" ]; then
  echo "Error: --code-repo is required."
  echo "Usage: $0 --code-repo <git-url-or-path> [options]"
  exit 1
fi

# --- Setup ---

RALPH_TZ="${RALPH_TZ:-America/Los_Angeles}"
CONSOLIDATOR_BASE="$HOME/.ralph-consolidator"
CODE_DIR="$CONSOLIDATOR_BASE/code"
LOG_DIR="$CONSOLIDATOR_BASE/logs"
CONFLICTS_DIR="$CONSOLIDATOR_BASE/conflicts"

mkdir -p "$CONSOLIDATOR_BASE" "$LOG_DIR" "$CONFLICTS_DIR"

# --- Date-Rotated Logging ---
LOG_DATE=$(TZ="$RALPH_TZ" date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${LOG_DATE}.log"
ln -sf "${LOG_DATE}.log" "$LOG_DIR/latest.log"

if [ -z "${__CONSOLIDATOR_LOGGING:-}" ]; then
  export __CONSOLIDATOR_LOGGING=1
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

find "$LOG_DIR" -name '*.log' -not -name 'latest.log' -mtime +180 -delete 2>/dev/null || true

# --- Single Instance Lock ---
PIDFILE="$CONSOLIDATOR_BASE/.consolidator.pid"

if [ -f "$PIDFILE" ]; then
  EXISTING_PID=$(cat "$PIDFILE")
  if kill -0 "$EXISTING_PID" 2>/dev/null; then
    # Verify the PID is actually a consolidator (not a recycled PID)
    if ps -p "$EXISTING_PID" -o command= 2>/dev/null | grep -q 'consolidator\.sh'; then
      echo "Error: consolidator.sh is already running (PID $EXISTING_PID)."
      echo "Kill it first: kill $EXISTING_PID"
      exit 1
    fi
    echo "Warning: stale PID $EXISTING_PID is not a consolidator. Removing pidfile."
  fi
  rm -f "$PIDFILE"
fi

echo $$ > "$PIDFILE"

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

# --- Clone/Update Code Repo ---

echo -e "$(ts) ${BOLD}Setting up consolidator...${RESET}"

if [ -d "$CODE_DIR/.git" ]; then
  echo -e "$(ts) ${DIM}Updating code repo...${RESET}"
  git -C "$CODE_DIR" fetch origin --quiet --prune
  git -C "$CODE_DIR" checkout main --quiet 2>/dev/null || git -C "$CODE_DIR" checkout -b main origin/main --quiet
  git -C "$CODE_DIR" reset --hard origin/main --quiet
else
  echo -e "$(ts) ${DIM}Cloning code repo...${RESET}"
  git clone "$CODE_REPO" "$CODE_DIR" --quiet
fi

# Set git identity for all consolidator commits (merges, conflict resolutions)
git -C "$CODE_DIR" config user.name "Ralph Wiggum"
git -C "$CODE_DIR" config user.email "ralph@opentabs.dev"

# --- Verify Claude CLI ---
CLAUDE_BIN=""
if command -v claude &>/dev/null; then
  CLAUDE_BIN=$(command -v claude)
  echo -e "$(ts) ${DIM}Claude CLI: $CLAUDE_BIN ($(claude --version 2>/dev/null | head -1))${RESET}"
else
  echo -e "$(ts) ${YELLOW}Warning: 'claude' CLI not found in PATH. AI conflict resolution will be unavailable.${RESET}"
  echo -e "$(ts) ${YELLOW}Install: npm install -g @anthropic-ai/claude-code${RESET}"
  echo -e "$(ts) ${YELLOW}PATH=$PATH${RESET}"
fi

# --- Cleanup ---

cleanup() {
  echo ""
  echo -e "$(ts) ${YELLOW}Shutting down consolidator...${RESET}"

  # Abort any in-progress merge
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true

  rm -f "$PIDFILE"
  echo -e "$(ts) ${GREEN}Consolidator stopped.${RESET}"
}

trap cleanup EXIT

# --- Helper Functions ---

# Short model label for log tags: "claude-opus" → "opus", "claude-sonnet" → "sonnet"
_model_label() {
  local m="$1"
  # Strip common prefixes to get a short label
  m="${m##*-}"    # claude-opus-4-20250514 → 20250514? No — take last meaningful segment
  case "$1" in
    *opus*)   echo "opus" ;;
    *sonnet*) echo "sonnet" ;;
    *haiku*)  echo "haiku" ;;
    *)        echo "$1" ;;
  esac
}

MODEL_LABEL=$(_model_label "$CONSOLIDATOR_MODEL")

# Extract short objective from branch name.
# ralph-2026-02-17-143000-improve-sdk → improve-sdk
_branch_objective() {
  local name="${1#origin/}"
  name="${name#ralph-}"
  # Strip timestamp prefix (YYYY-MM-DD-HHMMSS-)
  echo "${name:18}"
}

# Find all remote ralph-* branches, sorted by committer date (oldest first).
# This ensures branches are merged in the order they were completed.
find_ralph_branches() {
  git -C "$CODE_DIR" for-each-ref \
    --format='%(committerdate:unix) %(refname:short)' \
    'refs/remotes/origin/ralph-*' \
    2>/dev/null \
    | sort -n \
    | awk '{print $2}'
}

# Attempt to merge a single branch into main and push.
# Returns 0 on success, 1 on conflict.
merge_branch() {
  local remote_branch="$1"
  local branch_name="${remote_branch#origin/}"
  local objective
  objective=$(_branch_objective "$branch_name")
  local tag="M:${objective:0:20}:${MODEL_LABEL}"

  # Count commits to merge
  local commit_count
  commit_count=$(git -C "$CODE_DIR" rev-list --count "HEAD..$remote_branch" 2>/dev/null || echo "0")

  if [ "$commit_count" -eq 0 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}No commits to merge. Deleting remote branch.${RESET}"
    if [ "$DRY_RUN" = false ]; then
      git -C "$CODE_DIR" push origin --delete "$branch_name" 2>/dev/null || true
    fi
    return 0
  fi

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} Merging $branch_name ($commit_count commits)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}[dry-run] Would merge $branch_name${RESET}"
    return 0
  fi

  # Attempt the merge
  # --allow-unrelated-histories handles branches created from a different root
  # commit (e.g., after a repo re-init). Safe because content is the same codebase.
  local merge_output
  if merge_output=$(git -C "$CODE_DIR" merge --no-edit --allow-unrelated-histories "$remote_branch" 2>&1); then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Merged successfully.${RESET}"

    # Push main to remote — retry before giving up (preserves merge work)
    local push_ok=false
    for push_attempt in 1 2 3; do
      if git -C "$CODE_DIR" push origin main --quiet 2>/dev/null; then
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Pushed main.${RESET}"
        push_ok=true
        break
      fi
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push attempt $push_attempt failed. Retrying...${RESET}"
      sleep 1
    done

    if [ "$push_ok" = true ]; then
      # Delete the remote branch (it's merged)
      git -C "$CODE_DIR" push origin --delete "$branch_name" 2>/dev/null || true
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Deleted remote branch.${RESET}"
      return 0
    else
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push failed after 3 attempts. Resetting to remote.${RESET}"
      git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
      git -C "$CODE_DIR" reset --hard origin/main --quiet
      return 1
    fi
  else
    # Merge conflict — use AI to resolve
    # Use ls-files --unmerged for reliable conflict detection (catches rename/rename,
    # tree conflicts, etc. that --diff-filter=U can miss).
    local conflicted_files
    conflicted_files=$(git -C "$CODE_DIR" ls-files --unmerged 2>/dev/null | awk '{print $4}' | sort -u)
    if [ -z "$conflicted_files" ]; then
      # Fallback: diff --name-only --diff-filter=U
      conflicted_files=$(git -C "$CODE_DIR" diff --name-only --diff-filter=U 2>/dev/null)
    fi
    local conflict_count=0
    if [ -n "$conflicted_files" ]; then
      conflict_count=$(echo "$conflicted_files" | wc -l | tr -d ' ')
    fi

    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}MERGE CONFLICT ($conflict_count file(s))${RESET}"
    if [ -n "$conflicted_files" ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Conflicted: $(echo "$conflicted_files" | tr '\n' ' ')${RESET}"
    fi
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Merge output: $(echo "$merge_output" | head -5)${RESET}"

    # If no conflicted files detected, the merge failed for a non-content reason
    # (e.g., tree conflict, permission issue). Abort and write breadcrumb.
    if [ "$conflict_count" -eq 0 ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}No conflicted files — merge failed for a non-content reason.${RESET}"
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Aborting merge. Branch preserved for manual resolution.${RESET}"
      git -C "$CODE_DIR" merge --abort 2>/dev/null || git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

      local breadcrumb="$CONFLICTS_DIR/${branch_name}.merge-conflict.txt"
      {
        echo "MERGE FAILED — non-content conflict, manual resolution required"
        echo "================================================================="
        echo ""
        echo "Branch:    $branch_name"
        echo "Commits:   $commit_count"
        echo "Timestamp: $(date)"
        echo ""
        echo "Merge output:"
        echo "$merge_output"
        echo ""
        echo "To resolve:"
        echo "  cd $CODE_DIR"
        echo "  git fetch origin"
        echo "  git checkout main && git reset --hard origin/main"
        echo "  git merge origin/$branch_name"
        echo "  # Fix issues, then: git add . && git commit && git push origin main"
        echo "  git push origin --delete $branch_name"
      } > "$breadcrumb"
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Wrote: $breadcrumb${RESET}"
      return 1
    fi

    echo -e "$(ts) ${CYAN}[${tag}]${RESET} Invoking AI to resolve..."

    # Build context for AI: branch commits, conflicted file contents, PRD description
    local branch_log
    branch_log=$(git -C "$CODE_DIR" log --oneline "HEAD..$remote_branch" 2>/dev/null | head -20)

    local conflict_diff
    conflict_diff=$(git -C "$CODE_DIR" diff 2>/dev/null | head -500)

    local ai_prompt
    ai_prompt="You are resolving a git merge conflict. A branch is being merged into main.

## Branch: $branch_name
## Commits on this branch:
$branch_log

## Conflicted files:
$conflicted_files

## Current conflict markers (git diff, first 500 lines):
$conflict_diff

## Your task:
1. For each conflicted file, read the full file content (it contains conflict markers)
2. Understand the INTENT of both sides:
   - HEAD (main): the current state of main, which may include recent merges from other branches
   - The branch: changes from a specific PRD task (check the commit messages to understand what it was doing)
3. Resolve each conflict by keeping BOTH sets of changes where they don't contradict, or choosing the correct version when they do
4. Common patterns:
   - If both sides added different items to the same list/array/config: keep both
   - If the branch changed a function that main also changed: prefer main's structure, incorporate the branch's fix/feature
   - If it's a comment or documentation conflict: merge the text sensibly
   - If it's a package.json or lock file conflict: prefer main's version and re-add the branch's additions
5. After resolving ALL conflicts, stage the files with git add
6. Verify the resolution compiles: run npm run build && npm run type-check
7. If build fails, fix the issue
8. Do NOT commit. Just stage the resolved files. The consolidator will commit.

IMPORTANT: Do not be lazy. Read each conflicted file, understand both sides, and produce a correct merge. Do not just pick one side."

    # Run Claude to resolve the conflict.
    # Claude runs in --print mode with tool execution enabled. It reads the
    # conflicted files (which have conflict markers), edits them to resolve,
    # stages with git add, and verifies the build compiles.
    # Timeout: 10 minutes. Most conflicts resolve in 2-5 minutes.
    local ai_result_file
    ai_result_file=$(mktemp)
    local ai_stderr_file
    ai_stderr_file=$(mktemp)
    local ai_ok=false
    local ai_exit=0

    # Check that claude CLI is available before attempting AI resolution
    if [ -z "$CLAUDE_BIN" ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Skipping AI resolution: 'claude' CLI not found.${RESET}"
      ai_exit=127
    else
      # Run with timeout to prevent indefinite hangs.
      # Pass PATH explicitly so the subshell can find claude + node.
      # Stream stdout through a timestamped prefixer so progress is visible
      # in the log (like consumer workers). Also tee to result file for
      # post-processing. Stderr goes to a separate file.
      timeout 600 env PATH="$PATH" bash -c '
        set -o pipefail
        echo "$1" | (cd "$2" && claude \
          --dangerously-skip-permissions \
          --print \
          --model "$3" \
          --verbose \
          --output-format stream-json \
        ) 2>"$5" | tee "$4"
      ' _ "$ai_prompt" "$CODE_DIR" "$CONSOLIDATOR_MODEL" "$ai_result_file" "$ai_stderr_file" \
        2>&1 | while IFS= read -r line; do
          # Parse stream-json: extract text content, tool use, and results.
          # Skip raw JSON noise — only show meaningful progress lines.
          local msg=""
          if echo "$line" | grep -q '"type":"tool_use"' 2>/dev/null; then
            msg=$(echo "$line" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for c in d.get('message',{}).get('content',[]):
    if c.get('type')=='tool_use':
      name=c.get('name','')
      inp=c.get('input',{})
      if name in ('Edit','Write'):
        print(f'Tool: {name} → {inp.get(\"filePath\",inp.get(\"file_path\",\"\"))[:80]}')
      elif name=='Bash':
        print(f'Tool: {name} → {inp.get(\"command\",\"\")[:80]}')
      elif name=='Read':
        print(f'Tool: {name} → {inp.get(\"filePath\",inp.get(\"file_path\",\"\"))[:80]}')
      else:
        print(f'Tool: {name}')
except: pass" 2>/dev/null)
          elif echo "$line" | grep -q '"type":"text"' 2>/dev/null; then
            msg=$(echo "$line" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for c in d.get('message',{}).get('content',[]):
    if c.get('type')=='text':
      text=c['text'].strip().replace('\n',' ')
      # Show first meaningful line, truncated
      if len(text)>120: text=text[:120]+'…'
      if text: print(f'✦ {text}')
except: pass" 2>/dev/null)
          elif echo "$line" | grep -q '"type":"result"' 2>/dev/null; then
            msg=$(echo "$line" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  cost=d.get('total_cost_usd',0)
  dur=d.get('duration_ms',0)
  turns=d.get('num_turns',0)
  status=d.get('subtype','')
  print(f'Result: {status} ({turns} turns, {dur/1000:.1f}s, \${cost:.2f})')
except: pass" 2>/dev/null)
          fi
          if [ -n "$msg" ]; then
            echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}${msg}${RESET}"
          fi
        done
      ai_exit=${PIPESTATUS[0]}
    fi

    if [ "$ai_exit" -eq 124 ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI timed out after 10 minutes.${RESET}"
    elif [ "$ai_exit" -ne 0 ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI invocation failed (exit $ai_exit).${RESET}"
    else
      # Check if there are still unresolved conflicts (files with conflict markers)
      local remaining_conflicts
      remaining_conflicts=$(git -C "$CODE_DIR" diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')

      # Also check for leftover conflict markers in tracked files
      local marker_files
      marker_files=$(git -C "$CODE_DIR" grep -l '<<<<<<<' -- '*.ts' '*.tsx' '*.json' '*.md' 2>/dev/null | head -5)

      if [ "$remaining_conflicts" -eq 0 ] && [ -z "$marker_files" ]; then
        # AI resolved all conflicts — commit the merge
        # First check if Claude already committed (despite being told not to)
        local merge_in_progress
        merge_in_progress=$(git -C "$CODE_DIR" rev-parse -q --verify MERGE_HEAD 2>/dev/null && echo "yes" || echo "no")

        if [ "$merge_in_progress" = "yes" ]; then
          # Merge still in progress — we need to commit
          if git -C "$CODE_DIR" commit --no-edit 2>/dev/null; then
            echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}AI resolved conflict successfully.${RESET}"
            ai_ok=true
          else
            echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI staged files but commit failed.${RESET}"
          fi
        else
          # Claude already committed — check if HEAD advanced past the merge base
          echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}AI resolved conflict and committed.${RESET}"
          ai_ok=true
        fi
      else
        if [ -n "$marker_files" ]; then
          echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI left conflict markers in: $(echo "$marker_files" | tr '\n' ' ')${RESET}"
        else
          echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI left $remaining_conflicts unresolved conflicts.${RESET}"
        fi
      fi
    fi

    rm -f "$ai_result_file" "$ai_stderr_file"

    if [ "$ai_ok" = true ]; then
      # Push the AI-resolved merge
      local push_ok=false
      for push_attempt in 1 2 3; do
        if git -C "$CODE_DIR" push origin main --quiet 2>/dev/null; then
          echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Pushed main (AI-resolved merge).${RESET}"
          push_ok=true
          break
        fi
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push attempt $push_attempt failed. Retrying...${RESET}"
      done

      if [ "$push_ok" = true ]; then
        git -C "$CODE_DIR" push origin --delete "$branch_name" 2>/dev/null || true
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Deleted remote branch.${RESET}"
        return 0
      else
        echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push failed. Resetting to remote.${RESET}"
        git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
        git -C "$CODE_DIR" reset --hard origin/main --quiet
        return 1
      fi
    fi

    # AI failed to resolve — clean up and fall back to breadcrumb file
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}AI resolution failed. Writing breadcrumb.${RESET}"
    git -C "$CODE_DIR" merge --abort 2>/dev/null || git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

    local breadcrumb="$CONFLICTS_DIR/${branch_name}.merge-conflict.txt"
    {
      echo "MERGE CONFLICT — AI resolution failed, manual resolution required"
      echo "================================================================="
      echo ""
      echo "Branch:    $branch_name"
      echo "Commits:   $commit_count"
      echo "Timestamp: $(date)"
      echo ""
      echo "To resolve:"
      echo "  cd $CODE_DIR"
      echo "  git fetch origin"
      echo "  git checkout main && git reset --hard origin/main"
      echo "  git merge origin/$branch_name"
      echo "  # Fix conflicts, then:"
      echo "  git add <resolved files>"
      echo "  git commit"
      echo "  git push origin main"
      echo "  git push origin --delete $branch_name"
      echo ""
      echo "Conflicted files:"
      if [ -n "$conflicted_files" ]; then
        echo "$conflicted_files" | while IFS= read -r f; do echo "  - $f"; done
      else
        echo "  (could not determine — run the merge to see)"
      fi
      echo ""
      echo "Merge output:"
      echo "$merge_output"
    } > "$breadcrumb"

    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Wrote: $breadcrumb${RESET}"
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Branch preserved: origin/$branch_name${RESET}"
    return 1
  fi
}

# --- Main ---

echo ""
echo -e "$(ts) ${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "$(ts) ${BOLD}║  Ralph Consolidator — Branch Merger                      ║${RESET}"
echo -e "$(ts) ${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "$(ts)   Code repo:  ${CYAN}${CODE_REPO}${RESET}"
echo -e "$(ts)   Mode:       ${CYAN}$([ "$ONCE" = true ] && echo "single pass" || echo "daemon (poll every ${POLL_INTERVAL}s)")${RESET}"
echo -e "$(ts)   Dry run:    ${CYAN}$([ "$DRY_RUN" = true ] && echo "yes" || echo "no")${RESET}"
echo -e "$(ts)   AI model:   ${CYAN}${CONSOLIDATOR_MODEL}${RESET}"
echo -e "$(ts)   Base dir:   ${CYAN}${CONSOLIDATOR_BASE}${RESET}"
echo ""

while true; do
  # Ensure clean state — abort any stale merge from a previous iteration crash
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true
  git -C "$CODE_DIR" rebase --abort 2>/dev/null || true

  # Fetch all remote branches
  git -C "$CODE_DIR" fetch origin --quiet --prune 2>/dev/null || true

  # Reset main to remote HEAD (consolidator doesn't have local commits)
  git -C "$CODE_DIR" checkout main --quiet 2>/dev/null || true
  git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

  # Find ralph-* branches
  RALPH_BRANCHES=$(find_ralph_branches)

  if [ -n "$RALPH_BRANCHES" ]; then
    branch_count=$(echo "$RALPH_BRANCHES" | wc -l | tr -d ' ')
    echo -e "$(ts) ${BOLD}Found $branch_count ralph branch(es) to process.${RESET}"

    while IFS= read -r remote_branch; do
      [ -z "$remote_branch" ] && continue

      # Clean state before each merge — abort any stale merge/rebase from
      # a previous branch's failed resolution, then reset to remote HEAD.
      git -C "$CODE_DIR" merge --abort 2>/dev/null || true
      git -C "$CODE_DIR" rebase --abort 2>/dev/null || true
      git -C "$CODE_DIR" checkout main --quiet 2>/dev/null || true
      git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

      merge_branch "$remote_branch" || true

      # Re-fetch after each merge — another worker may have pushed a new branch
      # or main may have advanced.
      if [ "$DRY_RUN" = false ]; then
        git -C "$CODE_DIR" fetch origin --quiet --prune 2>/dev/null || true
      fi
    done <<< "$RALPH_BRANCHES"
  fi

  if [ "$ONCE" = true ]; then
    echo ""
    echo -e "$(ts) ${DIM}--once mode: done. Exiting.${RESET}"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
