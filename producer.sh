#!/bin/bash
# Producer — publishes PRD files to the opentabs-prds queue.
#
# Usage:
#   ./producer.sh <prd-file>              # Publish a single PRD (draft or ready)
#   ./producer.sh <prd-file> [<prd-file>] # Publish multiple PRDs in one commit
#
# The producer:
#   1. Validates each PRD file is valid JSON
#   2. Renames ~draft files with a timestamp (making them ready)
#   3. Commits and pushes to the opentabs-prds remote
#   4. Uses pull --rebase + retry if the push fails (concurrent workers claiming PRDs)
#
# PRD files can be passed as:
#   - A ~draft file:  prd-my-feature~draft.json  → renamed to prd-YYYY-MM-DD-HHMMSS-my-feature.json
#   - A ready file:   prd-2026-02-26-120000-my-feature.json → used as-is
#
# This script is meant to be called from the opentabs-prds repo directory,
# or from the Ralph skill after writing a PRD.

set -eo pipefail

# --- Argument Parsing ---

if [ $# -eq 0 ]; then
  echo "Usage: $0 <prd-file> [<prd-file> ...]"
  echo ""
  echo "Publish PRD files to the opentabs-prds queue."
  echo "Files with ~draft suffix are renamed with a timestamp."
  exit 1
fi

# --- Setup ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: $SCRIPT_DIR is not a git repository."
  exit 1
fi

# Ensure we're on main
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Error: must be on 'main' branch (currently on '$CURRENT_BRANCH')."
  exit 1
fi

# Abort any in-progress rebase from a previous crashed run
git rebase --abort 2>/dev/null || true

# Discard any dirty working tree state from a previous crashed run
# (only unstaged changes — staged changes indicate intentional work)
if ! git diff --quiet 2>/dev/null; then
  echo "Warning: dirty working tree detected. Resetting unstaged changes..."
  git checkout -- . 2>/dev/null || true
fi

# Fetch latest before publishing to minimize push failures
if ! git fetch origin main --quiet; then
  echo "Error: git fetch failed. Check network connectivity and remote URL."
  exit 1
fi

# Ensure local main is at or ahead of remote — rebase if behind
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
  BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
  if [ "$BASE" = "$LOCAL" ]; then
    echo "Local is behind remote. Rebasing..."
    if ! git rebase origin/main --quiet; then
      echo "Error: rebase failed. Resolve manually: git rebase --abort && git reset --hard origin/main"
      exit 1
    fi
  elif [ "$BASE" = "$REMOTE" ]; then
    echo "Local is ahead of remote (unpushed commits). Proceeding."
  else
    echo "Error: local and remote have diverged. Resolve manually."
    exit 1
  fi
fi

# --- Validate and Prepare PRD Files ---

PUBLISHED_FILES=()

for prd_file in "$@"; do
  # Resolve to basename if a path was given
  if [ ! -f "$prd_file" ]; then
    echo "Error: file not found: $prd_file"
    exit 1
  fi

  # Validate JSON
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$prd_file" 2>/dev/null; then
    echo "Error: invalid JSON: $prd_file"
    exit 1
  fi

  # Validate required fields
  local_project=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('project',''))" "$prd_file" 2>/dev/null)
  local_stories=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('userStories',[])))" "$prd_file" 2>/dev/null)

  if [ -z "$local_project" ]; then
    echo "Error: PRD missing 'project' field: $prd_file"
    exit 1
  fi
  if [ "$local_stories" = "0" ]; then
    echo "Error: PRD has no userStories: $prd_file"
    exit 1
  fi

  base=$(basename "$prd_file")

  # If it's a ~draft file, rename with timestamp and content hash
  if [[ "$base" == *"~draft"* ]]; then
    # Extract the slug: prd-my-feature~draft.json → my-feature
    slug="${base#prd-}"
    slug="${slug%~draft.json}"
    timestamp=$(date '+%Y-%m-%d-%H%M%S')
    # Content hash (first 6 chars of SHA-256) ensures unique branch names
    # even if the same slug is used for different PRDs
    content_hash=$(sha256sum "$prd_file" 2>/dev/null | head -c 6 || shasum -a 256 "$prd_file" 2>/dev/null | head -c 6)
    ready_name="prd-${timestamp}-${slug}-${content_hash}.json"

    # Move/rename the file and remove the draft from git index
    if [ "$(dirname "$prd_file")" = "." ] || [ "$(dirname "$prd_file")" = "$SCRIPT_DIR" ]; then
      mv "$prd_file" "$ready_name"
      # Remove the old draft name from git (file already moved on disk)
      git rm --cached --quiet "$base" 2>/dev/null || true
    else
      cp "$prd_file" "$ready_name"
      rm "$prd_file"
    fi

    echo "Published: $base → $ready_name"
    PUBLISHED_FILES+=("$ready_name")
  else
    # Already a ready file — just use it
    if [[ "$base" != prd-*-*-*.json ]]; then
      echo "Warning: file doesn't match expected naming (prd-YYYY-MM-DD-HHMMSS-slug.json): $base"
    fi
    echo "Published: $base (already ready)"
    PUBLISHED_FILES+=("$base")
  fi
done

if [ ${#PUBLISHED_FILES[@]} -eq 0 ]; then
  echo "No files to publish."
  exit 0
fi

# --- Commit and Push ---

# Stage all published files
for f in "${PUBLISHED_FILES[@]}"; do
  git add "$f"
done

# Build commit message
if [ ${#PUBLISHED_FILES[@]} -eq 1 ]; then
  commit_msg="publish: ${PUBLISHED_FILES[0]}"
else
  commit_msg="publish: ${#PUBLISHED_FILES[@]} PRDs"
fi

# Commit
git commit -m "$commit_msg" --quiet

# Push with retry — handles concurrent pushes from workers or other producers.
# PRD additions never conflict with PRD claims (different files), so rebase
# always succeeds cleanly.
MAX_RETRIES=5
for attempt in $(seq 1 $MAX_RETRIES); do
  if git push origin main --quiet 2>&1; then
    echo ""
    echo "Pushed to remote (attempt $attempt)."
    echo ""
    echo "Published ${#PUBLISHED_FILES[@]} PRD(s):"
    for f in "${PUBLISHED_FILES[@]}"; do
      stories=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('userStories',[])))" "$f" 2>/dev/null)
      project=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('project','unknown'))" "$f" 2>/dev/null)
      echo "  $f ($stories stories, project: $project)"
    done
    exit 0
  fi

  echo "Push failed (attempt $attempt/$MAX_RETRIES). Rebasing and retrying..."
  if ! git fetch origin main --quiet; then
    echo "Error: git fetch failed during retry. Check network."
    exit 1
  fi
  if ! git rebase origin/main --quiet 2>/dev/null; then
    echo "Error: rebase failed during retry. This should not happen (disjoint files)."
    echo "Aborting rebase and resetting to remote state."
    git rebase --abort 2>/dev/null || true
    git reset --hard origin/main --quiet
    # Re-stage and re-commit our files on top of the clean remote state
    for f in "${PUBLISHED_FILES[@]}"; do
      if [ ! -f "$f" ]; then
        echo "Error: published file $f lost after reset. Manual recovery needed."
        exit 1
      fi
      git add "$f"
    done
    git commit -m "$commit_msg" --quiet
  fi
  sleep 1
done

echo "Error: push failed after $MAX_RETRIES attempts. Manual intervention needed."
exit 1
