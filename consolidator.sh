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
# Design:
#   The shell loop is intentionally minimal. For each branch it:
#     1. Tries fast-forward merge + push (up to 3 attempts)
#     2. If that fails, hands EVERYTHING to AI — merge, conflict resolution,
#        build fixing, committing, and pushing. The shell just watches for
#        the <promise>MERGED</promise> quit signal.
#   This avoids the combinatorial explosion of shell-side error handling that
#   plagued the previous version (misdiagnosing non-ff as build failure,
#   wasted AI calls, infinite retry loops).

# NOTE: set -e is intentionally NOT used.

# --- Ensure user-local npm binaries are on PATH ---
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

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [ "$POLL_INTERVAL" -lt 1 ]; then
  echo "Error: --poll must be a positive integer (got '$POLL_INTERVAL')."
  exit 1
fi

# --- Setup ---

RALPH_TZ="${RALPH_TZ:-America/Los_Angeles}"
CONSOLIDATOR_BASE="$HOME/.ralph-consolidator"
CODE_DIR="$CONSOLIDATOR_BASE/code"
LOG_DIR="$CONSOLIDATOR_BASE/logs"
CONFLICTS_DIR="$CONSOLIDATOR_BASE/conflicts"

mkdir -p "$CONSOLIDATOR_BASE" "$LOG_DIR" "$CONFLICTS_DIR"
chmod 700 "$CONSOLIDATOR_BASE" 2>/dev/null || true

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
    if ps -p "$EXISTING_PID" -o command= 2>/dev/null | grep -q 'consolidator\.sh'; then
      echo "Error: consolidator.sh is already running (PID $EXISTING_PID)."
      echo "Kill it first: kill $EXISTING_PID"
      exit 1
    fi
    echo "Warning: stale PID $EXISTING_PID is not a consolidator. Removing pidfile."
  fi
  rm -f "$PIDFILE"
fi

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

git -C "$CODE_DIR" config user.name "Ralph Wiggum"
git -C "$CODE_DIR" config user.email "ralph@opentabs.dev"

# --- Verify Claude CLI ---
CLAUDE_BIN=""
if command -v claude &>/dev/null; then
  CLAUDE_BIN=$(command -v claude)
  echo -e "$(ts) ${DIM}Claude CLI: $CLAUDE_BIN ($(claude --version 2>/dev/null | head -1))${RESET}"
else
  echo -e "$(ts) ${YELLOW}Warning: 'claude' CLI not found in PATH. AI merge will be unavailable.${RESET}"
fi

# --- Cleanup ---

cleanup() {
  echo ""
  echo -e "$(ts) ${YELLOW}Shutting down consolidator...${RESET}"
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true
  rm -f "$PIDFILE"
  echo -e "$(ts) ${GREEN}Consolidator stopped.${RESET}"
}

trap cleanup EXIT

# --- Helper Functions ---

# Short model label for log tags: "claude-opus" → "opus"
_model_label() {
  case "$1" in
    *opus*)   echo "opus" ;;
    *sonnet*) echo "sonnet" ;;
    *haiku*)  echo "haiku" ;;
    *)        echo "$1" ;;
  esac
}

MODEL_LABEL=$(_model_label "$CONSOLIDATOR_MODEL")

# Extract short objective from branch name.
# ralph-2026-02-17-143000-improve-sdk-a1b2c3-merge-ready → improve-sdk
_branch_objective() {
  local name="${1#origin/}"
  name="${name#ralph-}"
  name="${name%-merge-ready}"
  local after_ts="${name:18}"
  echo "${after_ts%-??????}"
}

# Derive the work branch name from a -merge-ready branch.
_work_branch_from_ready() {
  local name="${1#origin/}"
  echo "${name%-merge-ready}"
}

# Find all remote ralph-*-merge-ready branches, sorted by committer date (oldest first).
find_ralph_branches() {
  git -C "$CODE_DIR" for-each-ref \
    --format='%(committerdate:unix) %(refname:short)' \
    'refs/remotes/origin/ralph-*-merge-ready' \
    2>/dev/null \
    | sort -n \
    | awk '{print $2}'
}

# Delete the -merge-ready signal branch after verifying the merge landed.
# ONLY deletes the signal branch. The work branch is NEVER deleted.
_delete_merge_ready_branch() {
  local tag="$1"
  local merge_ready_branch="$2"

  # Fetch latest remote state
  git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true

  local remote_main
  remote_main=$(git -C "$CODE_DIR" rev-parse origin/main 2>/dev/null)

  # Verify the branch tip is an ancestor of main (i.e., merged)
  local branch_tip
  branch_tip=$(git -C "$CODE_DIR" rev-parse "origin/$merge_ready_branch" 2>/dev/null || true)
  if [ -n "$branch_tip" ] && git -C "$CODE_DIR" merge-base --is-ancestor "$branch_tip" "$remote_main" 2>/dev/null; then
    : # verified
  else
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}SAFETY: Merge not verified on origin/main. Keeping -merge-ready branch.${RESET}"
    return 1
  fi

  # Delete the signal branch (retry once on failure)
  if ! git -C "$CODE_DIR" push origin --delete "$merge_ready_branch" 2>/dev/null; then
    sleep 2
    git -C "$CODE_DIR" push origin --delete "$merge_ready_branch" 2>/dev/null || \
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Failed to delete -merge-ready branch (may already be gone).${RESET}"
  fi

  git -C "$CODE_DIR" branch -D "$merge_ready_branch" 2>/dev/null || true

  # Clean up consumer worktree
  local work_branch
  work_branch=$(_work_branch_from_ready "$merge_ready_branch")
  local slug="${work_branch#ralph-}"
  local worktree_path="$HOME/.ralph-consumer/worktrees/$slug"

  if [ -d "$worktree_path" ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}Cleaning up consumer worktree: $slug${RESET}"
    local consumer_code="$HOME/.ralph-consumer/code"
    if [ -d "$consumer_code/.git" ]; then
      git -C "$consumer_code" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    fi
    rm -rf "$worktree_path" 2>/dev/null || true
  fi

  return 0
}

# Stream filter: parse claude's stream-json output and log progress.
# Also writes text content to $1 so we can detect <promise>MERGED</promise>.
_stream_filter() {
  local result_file="$1"
  local tag="$2"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
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
      # Extract text and check for quit signal
      local text_content
      text_content=$(echo "$line" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for c in d.get('message',{}).get('content',[]):
    if c.get('type')=='text':
      print(c['text'])
except: pass" 2>/dev/null)

      if [ -n "$text_content" ] && [ "$text_content" != "null" ]; then
        # Log a truncated version
        local display_text
        display_text=$(echo "$text_content" | head -3 | tr '\n' ' ')
        if [ ${#display_text} -gt 120 ]; then
          display_text="${display_text:0:120}..."
        fi
        msg="$display_text"

        # Write to result file for quit signal detection
        echo "$text_content" >> "$result_file"
      fi
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
}

# --- merge_branch: the core logic ---
#
# Strategy:
#   1. Try fast-forward merge + push up to 3 times (pure shell, no AI)
#   2. If ff fails (conflicts or push race), hand everything to AI
#   3. AI merges, resolves conflicts, fixes build, commits, pushes
#   4. Shell watches for <promise>MERGED</promise> quit signal

merge_branch() {
  local remote_branch="$1"
  local merge_ready_branch="${remote_branch#origin/}"
  local work_branch
  work_branch=$(_work_branch_from_ready "$merge_ready_branch")
  local objective
  objective=$(_branch_objective "$merge_ready_branch")
  local tag="M:${objective:0:20}:${MODEL_LABEL}"
  local work_remote="origin/$work_branch"

  # Verify the work branch exists
  if ! git -C "$CODE_DIR" rev-parse "$work_remote" &>/dev/null; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Work branch $work_branch not found on remote. Skipping.${RESET}"
    return 1
  fi

  # Count commits
  local commit_count
  commit_count=$(git -C "$CODE_DIR" rev-list --count "HEAD..$work_remote" 2>/dev/null || echo "0")

  if [ "$commit_count" -eq 0 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}No commits to merge.${RESET}"
    [ "$DRY_RUN" = false ] && _delete_merge_ready_branch "$tag" "$merge_ready_branch"
    return 0
  fi

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} Merging $work_branch ($commit_count commits)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${DIM}[dry-run] Would merge $work_branch${RESET}"
    return 0
  fi

  # --- Phase 1: Try fast-forward merge + push (3 attempts, no AI) ---
  local ff_succeeded=false

  for attempt in 1 2 3; do
    # Always start from clean remote HEAD
    git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
    git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

    # Try the merge
    if ! git -C "$CODE_DIR" merge --no-edit "$work_remote" 2>/dev/null; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Merge has conflicts — handing to AI.${RESET}"
      git -C "$CODE_DIR" merge --abort 2>/dev/null || true
      break
    fi

    # Merge succeeded — try push
    local push_output
    push_output=$(git -C "$CODE_DIR" push origin main 2>&1)
    if [ $? -eq 0 ]; then
      echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}Fast-forward merged and pushed (attempt $attempt).${RESET}"
      ff_succeeded=true
      break
    fi

    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Push failed (attempt $attempt/3). Retrying...${RESET}"
    sleep 2
  done

  if [ "$ff_succeeded" = true ]; then
    _delete_merge_ready_branch "$tag" "$merge_ready_branch"
    return 0
  fi

  # --- Phase 2: Hand everything to AI ---

  if [ -z "$CLAUDE_BIN" ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}Claude CLI not found. Cannot resolve. Skipping.${RESET}"
    git -C "$CODE_DIR" merge --abort 2>/dev/null || true
    git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true
    return 1
  fi

  # Reset to clean state before AI takes over
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true
  git -C "$CODE_DIR" rebase --abort 2>/dev/null || true
  git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
  git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${BOLD}Invoking AI to merge, resolve, and push...${RESET}"

  local branch_log
  branch_log=$(git -C "$CODE_DIR" log --oneline "HEAD..$work_remote" 2>/dev/null | head -20)

  # Derive the PRD slug from the work branch so AI can find its PRD file.
  # Branch: ralph-2026-03-03-225512-tool-summary-field-78b20c
  # PRD:    .ralph/prd-2026-03-03-225512-tool-summary-field-78b20c~running.json
  local work_slug="${work_branch#ralph-}"

  # List recent PRD files (running + done) so AI understands the broader context
  # of concurrent work — helps make better conflict resolution decisions.
  local prd_listing
  prd_listing=$(ls -1 "$CODE_DIR/.ralph/"prd-*~running.json "$CODE_DIR/.ralph/"prd-*~done.json 2>/dev/null \
    | xargs -I{} basename {} | head -20)

  local ai_prompt
  ai_prompt="You are merging a feature branch into main in a TypeScript monorepo.

## Branch to merge: origin/$work_branch
## Commits on this branch:
$branch_log

## Your task — do ALL of these steps:

### Step 0: Understand the branch's intent
Read the PRD file for this branch to understand what it was trying to accomplish:
\`\`\`bash
cat .ralph/prd-${work_slug}~running.json 2>/dev/null || cat .ralph/prd-${work_slug}~done.json 2>/dev/null || echo 'PRD not found'
\`\`\`
The PRD contains a \`description\` and \`userStories\` that explain what this branch was doing.
This context is critical for making correct conflict resolution decisions.

Other PRDs currently in flight (for broader context on concurrent work):
${prd_listing:-  (none found)}

If conflicts touch code related to other in-flight PRDs, reading those PRDs too will
help you understand the intent of the other side (HEAD/main).

### Step 1: Pull latest main and merge
Always start from the latest remote state:
\`\`\`bash
git fetch origin main
git reset --hard origin/main
git merge --no-edit origin/$work_branch
\`\`\`

### Step 2: If there are merge conflicts, resolve them
- Read each conflicted file (they contain conflict markers)
- Use the PRD description + commit messages to understand the INTENT of the branch's changes
- HEAD (main) = current state, may include recent merges from other concurrent branches
- The branch = changes from a specific PRD task
- Common patterns:
  - Both sides added different items to a list/array/config → keep both
  - Both sides changed the same function → prefer main's structure, incorporate the branch's feature/fix
  - If it's a comment or documentation conflict → merge the text sensibly
  - package.json / lock file conflicts → prefer main's versions, re-add the branch's new dependencies
- Stage resolved files with \`git add\`

### Step 3: Verify the build passes
Run: \`npm run build && npm run type-check\`
- If the build fails, fix the source code and re-run until it passes
- Also run: \`npm run build:plugins\` (if it exists — ignore if command not found)

### Step 4: Commit the merge
- If the merge is still in progress (MERGE_HEAD exists): \`git commit --no-edit\`
- If you had to fix build issues after committing: \`git add -A && git commit --amend --no-edit\`

### Step 5: Push to remote
Run: \`git push origin main\`
- If the push is rejected (non-fast-forward — remote advanced while you were working):
  \`\`\`bash
  git fetch origin main
  git rebase origin/main
  git push origin main
  \`\`\`
- If rebase has conflicts, resolve them, \`git rebase --continue\`, then push
- Retry push up to 3 times if needed

### Step 6: Signal completion
When the push succeeds, output exactly:
<promise>MERGED</promise>

## Rules:
- Do NOT refactor or change unrelated code
- Do NOT delete any branches
- Focus only on getting this merge landed on main
- If you truly cannot resolve (e.g., the branch is fundamentally incompatible), just stop without outputting the promise"

  local ai_result_file ai_stderr_file
  ai_result_file=$(mktemp) && chmod 600 "$ai_result_file"
  ai_stderr_file=$(mktemp) && chmod 600 "$ai_stderr_file"

  # Run AI with 15-minute timeout (it now handles everything including push retries)
  timeout 900 env PATH="$PATH" bash -c '
    set -o pipefail
    echo "$1" | (cd "$2" && claude \
      --dangerously-skip-permissions \
      --print \
      --model "$3" \
      --verbose \
      --output-format stream-json \
    ) 2>"$5" | tee "$4"
  ' _ "$ai_prompt" "$CODE_DIR" "$CONSOLIDATOR_MODEL" "$ai_result_file" "$ai_stderr_file" \
    2>&1 | _stream_filter "$ai_result_file" "$tag"
  local ai_exit=${PIPESTATUS[0]}

  # Check for the quit signal
  local merged=false
  if grep -q '<promise>MERGED</promise>' "$ai_result_file" 2>/dev/null; then
    merged=true
  fi

  rm -f "$ai_result_file" "$ai_stderr_file"

  if [ "$merged" = true ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${GREEN}AI merged and pushed successfully.${RESET}"
    _delete_merge_ready_branch "$tag" "$merge_ready_branch"
    return 0
  fi

  # AI did not signal success
  if [ "$ai_exit" -eq 124 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI timed out (15 min).${RESET}"
  elif [ "$ai_exit" -ne 0 ]; then
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI failed (exit $ai_exit).${RESET}"
  else
    echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${RED}AI finished without signaling MERGED.${RESET}"
  fi

  # Reset to clean state
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true
  git -C "$CODE_DIR" rebase --abort 2>/dev/null || true
  git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
  git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

  echo -e "$(ts) ${CYAN}[${tag}]${RESET} ${YELLOW}Branch preserved for next attempt: origin/$work_branch${RESET}"
  return 1
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
  # Clean state
  git -C "$CODE_DIR" merge --abort 2>/dev/null || true
  git -C "$CODE_DIR" rebase --abort 2>/dev/null || true
  git -C "$CODE_DIR" fetch origin --quiet --prune 2>/dev/null || true
  git -C "$CODE_DIR" checkout main --quiet 2>/dev/null || true
  git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

  # Find branches
  RALPH_BRANCHES=$(find_ralph_branches)

  if [ -n "$RALPH_BRANCHES" ]; then
    branch_count=$(echo "$RALPH_BRANCHES" | wc -l | tr -d ' ')
    echo -e "$(ts) ${BOLD}Found $branch_count ralph branch(es) to process.${RESET}"

    while IFS= read -r remote_branch; do
      [ -z "$remote_branch" ] && continue

      # Reset to remote before each branch
      git -C "$CODE_DIR" merge --abort 2>/dev/null || true
      git -C "$CODE_DIR" rebase --abort 2>/dev/null || true
      git -C "$CODE_DIR" fetch origin main --quiet 2>/dev/null || true
      git -C "$CODE_DIR" reset --hard origin/main --quiet 2>/dev/null || true

      merge_branch "$remote_branch" || true

      # Re-fetch after each merge
      [ "$DRY_RUN" = false ] && git -C "$CODE_DIR" fetch origin --quiet --prune 2>/dev/null || true
    done <<< "$RALPH_BRANCHES"
  fi

  if [ "$ONCE" = true ]; then
    echo ""
    echo -e "$(ts) ${DIM}--once mode: done. Exiting.${RESET}"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
