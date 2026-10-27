#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-flow — Generic GitHub Issue & PR Lifecycle CLI
# =============================================================================

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
NC=$'\033[0m' # No Color

log() {
  echo -e "${BLUE}==>${NC} $*"
}

success() {
  echo -e "${GREEN}✓${NC} $*"
}

warn() {
  echo -e "${YELLOW}!${NC} $*"
}

error() {
  echo -e "${RED}✗ Error:${NC} $*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Configuration Loading
# -----------------------------------------------------------------------------
REPO_ROOT=$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && pwd -P)

# Load configuration from .flowrc if present
if [[ -f "$REPO_ROOT/.flowrc" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.flowrc"
elif [[ -f "./.flowrc" ]]; then
  # shellcheck source=/dev/null
  source "./.flowrc"
fi

# Detect repository metadata via gh
REPO_OWNER="${REPO_OWNER:-$(gh repo view --json owner --jq .owner.login 2>/dev/null || echo "")}"
REPO_NAME="${REPO_NAME:-$(gh repo view --json name --jq .name 2>/dev/null || echo "")}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")}"

# Fallback to git remote if gh repo view failed (offline, sandboxed, or unauthenticated)
if [[ -z "$REPO_OWNER" || -z "$REPO_NAME" ]]; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
  if [[ -n "$REMOTE_URL" ]]; then
    REPO_OWNER="${REPO_OWNER:-$(echo "$REMOTE_URL" | sed -E 's/.*github\.com[:\/]([^\/]+)\/([^\/\.]+)(\.git)?/\1/' 2>/dev/null || true)}"
    REPO_NAME="${REPO_NAME:-$(echo "$REMOTE_URL" | sed -E 's/.*github\.com[:\/]([^\/]+)\/([^\/\.]+)(\.git)?/\2/' 2>/dev/null || true)}"
  fi
fi

# Fallback default branch detection.
# NOTE: `cmd | sed ... || echo main` does NOT fall back — sed exits 0 with empty
# output when the ref is missing, so the || branch never runs. Capture and test.
if [[ -z "$DEFAULT_BRANCH" ]]; then
  _symbolic_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  DEFAULT_BRANCH="$_symbolic_head"
fi
if [[ -z "$DEFAULT_BRANCH" ]]; then
  # Last resort: the branch HEAD currently points at, else literal "main".
  _current=$(git branch --show-current 2>/dev/null || true)
  DEFAULT_BRANCH="${_current:-main}"
fi
unset _symbolic_head _current 2>/dev/null || true

# Workflow defaults
BRANCH_PREFIX="${BRANCH_PREFIX:-feature/}"
CHECK_CMD="${CHECK_CMD:-}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g'
}

clean_issue_title() {
  local title="$1"
  # Strip common prefix tracker identifiers like EP-01 / 1-4 —, PROJ-123:, [Bug]
  echo "$title" \
    | sed -E 's/^[A-Za-z0-9_-]+[ ]*\/[ ]*[0-9]+-[0-9]+[ ]*([—–-]|:)[ ]*//' \
    | sed -E 's/^[A-Za-z0-9_-]+[ ]*([—–-]|:)[ ]*//' \
    | sed -E 's/^\[[^]]+\][ ]*//' \
    | sed -E 's/^[A-Za-z0-9_-]+:[ ]*//'
}

detect_check_command() {
  if [[ -n "$CHECK_CMD" ]]; then
    echo "$CHECK_CMD"
    return 0
  fi

  if [[ -f "$REPO_ROOT/pnpm-workspace.yaml" ]]; then
    echo "pnpm -r --parallel run typecheck && pnpm build"
  elif [[ -f "$REPO_ROOT/package.json" ]]; then
    if grep -q '"check":' "$REPO_ROOT/package.json"; then
      echo "npm run check"
    elif grep -q '"test":' "$REPO_ROOT/package.json"; then
      echo "npm test"
    elif grep -q '"build":' "$REPO_ROOT/package.json"; then
      echo "npm run build"
    else
      echo "git status -sb"
    fi
  elif [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo "cargo check && cargo test"
  elif [[ -f "$REPO_ROOT/Makefile" ]]; then
    if grep -q '^check:' "$REPO_ROOT/Makefile"; then
      echo "make check"
    else
      echo "make test"
    fi
  else
    echo "git status -sb"
  fi
}

resolve_flow_cmd() {
  if [[ -f "$REPO_ROOT/package.json" ]] && grep -q '"flow":' "$REPO_ROOT/package.json"; then
    if [[ -f "$REPO_ROOT/pnpm-lock.yaml" ]]; then
      echo "pnpm flow"
    elif [[ -f "$REPO_ROOT/yarn.lock" ]]; then
      echo "yarn flow"
    elif [[ -f "$REPO_ROOT/bun.lockb" || -f "$REPO_ROOT/bun.lock" ]]; then
      echo "bun flow"
    else
      echo "npm run flow --"
    fi
  else
    echo "./scripts/flow.sh"
  fi
}

# Absolute path to this flow.sh (works when invoked via pnpm/npm wrappers)
flow_script_abs() {
  local src dir
  src="${BASH_SOURCE[0]}"
  dir=$(cd "$(dirname "$src")" && pwd -P)
  echo "$dir/$(basename "$src")"
}

# Path to flow.sh relative to REPO_ROOT (for package.json scripts.flow)
flow_script_rel() {
  local abs root
  abs=$(flow_script_abs)
  root=$(cd "$REPO_ROOT" && pwd -P)
  local rel="${abs#"$root"/}"
  if [[ "$rel" == "$abs" ]]; then
    error "flow.sh is outside the repository root ($root). Cannot wire package.json."
  fi
  echo "$rel"
}

flow_skill_dir() {
  local abs
  abs=$(flow_script_abs)
  dirname "$(dirname "$abs")"
}

# "Deletable" is decided by content, not ancestry. Squash merges rewrite commits,
# so a merged branch is never an ancestor of the default branch and
# `git branch --merged` reports nothing.
#
# Two independent signals make a branch deletable:
#   1. A merged PR exists for it (authoritative, straight from GitHub).
#   2. It carries no net change: merging it into the default branch is a no-op.
#      This catches duplicates whose PR was merged under a different branch
#      (e.g. #214 vs #215) and branches that never had a PR at all.
MERGE_TREE_OK="false"
if git merge-tree --write-tree HEAD HEAD > /dev/null 2>&1; then
  MERGE_TREE_OK="true"
fi

# True when merging the given revision into the default branch changes nothing.
# Callers pass a name git can resolve unambiguously (local branch, or "origin/x").
branch_is_redundant() {
  local rev="$1"
  local merged_tree main_tree

  if [[ "$MERGE_TREE_OK" == "true" ]]; then
    merged_tree=$(git merge-tree --write-tree "$DEFAULT_BRANCH" "$rev" 2>/dev/null | head -n1 || true)
    main_tree=$(git rev-parse "$DEFAULT_BRANCH^{tree}" 2>/dev/null || true)
    # Only trust merge-tree when it actually produced a tree for a resolvable rev.
    if [[ -n "$merged_tree" && -n "$main_tree" ]]; then
      [[ "$merged_tree" == "$main_tree" ]]
      return
    fi
  fi

  # Fallback for git < 2.38 or unresolvable revs: patch-equivalence check.
  # No '+' lines means every commit's patch already landed upstream.
  if git cherry "$DEFAULT_BRANCH" "$rev" 2>/dev/null | grep -q '^+'; then
    return 1
  fi
  return 0
}

# Returns the PR number whose head ref matches the branch, or empty.
open_pr_number_for() {
  local branch="$1" open_prs="$2"
  [[ -z "$open_prs" ]] && return 0
  printf '%s\n' "$open_prs" | awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }'
}

# Prints one of:
#   deletable | default branch | currently checked out | open PR | no PR
# Names that must never be deleted, even if every other signal says "deletable".
# Content checks call a default branch "redundant" by definition (merging main
# into main changes nothing), so this name guard is the ONLY thing protecting it.
is_protected_branch_name() {
  local branch="$1"
  [[ -z "$branch" ]] && return 0
  [[ "$branch" == "HEAD" ]] && return 0
  [[ "$branch" == "main" || "$branch" == "master" ]] && return 0
  [[ -n "$DEFAULT_BRANCH" && "$branch" == "$DEFAULT_BRANCH" ]] && return 0
  # Refuse anything that could be mistaken for a remote-tracking ref or option.
  [[ "$branch" == -* || "$branch" == *".."* ]] && return 0
  return 1
}

branch_cleanup_verdict() {
  local branch="$1" merged_refs="$2" open_refs="$3" current_branch="$4" rev="${5:-$1}"

  if is_protected_branch_name "$branch"; then
    echo "default branch"
    return 0
  fi
  if [[ -n "$current_branch" && "$branch" == "$current_branch" ]]; then
    echo "currently checked out"
    return 0
  fi
  if [[ -n "$merged_refs" ]] && printf '%s\n' "$merged_refs" | grep -qxF -- "$branch"; then
    echo "deletable"
    return 0
  fi
  if branch_is_redundant "$rev"; then
    echo "deletable"
    return 0
  fi
  if [[ -n "$open_refs" ]] && printf '%s\n' "$open_refs" | grep -qxF -- "$branch"; then
    echo "open PR"
    return 0
  fi
  echo "no PR"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_init() {
  local pkg="$REPO_ROOT/package.json"
  local flowrc="$REPO_ROOT/.flowrc"
  local example
  example="$(flow_skill_dir)/references/flowrc.example"
  local script_rel
  script_rel=$(flow_script_rel)
  local flow_cmd="bash $script_rel"

  log "Initializing github-flow in $REPO_ROOT"

  if [[ ! -f "$pkg" ]]; then
    warn "No package.json at repo root — skipped scripts.flow"
  else
    command -v jq >/dev/null 2>&1 || error "jq is required to update package.json"
    local existing
    existing=$(jq -r '.scripts.flow // empty' "$pkg" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      if [[ "$existing" == "$flow_cmd" ]]; then
        success "package.json scripts.flow already set"
      else
        warn "package.json already has scripts.flow — leaving unchanged"
        echo "  current: $existing"
        echo "  wanted:  $flow_cmd"
      fi
    else
      local tmp
      tmp=$(mktemp)
      jq --arg cmd "$flow_cmd" '.scripts = ((.scripts // {}) + {flow: $cmd})' "$pkg" > "$tmp"
      mv "$tmp" "$pkg"
      success "Added scripts.flow → $flow_cmd"
    fi
  fi

  if [[ -f "$flowrc" ]]; then
    warn ".flowrc already exists — leaving unchanged"
  else
    [[ -f "$example" ]] || error "Missing template: $example"
    cp "$example" "$flowrc"
    success "Created .flowrc from references/flowrc.example"
  fi

  echo ""
  success "github-flow init complete"
  echo "Next step: pick up work with:"
  echo -e "  ${GREEN}$(resolve_flow_cmd) next${NC}"
}

cmd_start() {
  local issue_no="${1:-}"
  local slug_arg="${2:-}"

  [[ -z "$issue_no" ]] && error "Usage: $0 start <issue_number> [branch_slug]"

  log "Fetching details for issue #$issue_no..."
  local issue_json
  issue_json=$(gh issue view "$issue_no" --json id,title,state,milestone 2>/dev/null) || error "Issue #$issue_no not found."

  local issue_title
  issue_title=$(echo "$issue_json" | jq -r .title)
  log "Target Issue: #$issue_no - $issue_title"

  if [[ -n $(git status --porcelain) ]]; then
    error "Working tree has uncommitted changes. Stash or commit before starting."
  fi

  log "Syncing with origin/$DEFAULT_BRANCH..."
  git switch "$DEFAULT_BRANCH"

  # Fetch latest remote state; prune stale origin/* tracking refs (e.g. deleted feature branches)
  git fetch --prune origin > /dev/null 2>&1 || true

  # Check if local DEFAULT_BRANCH has unpushed commits ahead of origin
  local ahead_count
  ahead_count=$(git rev-list --count "origin/$DEFAULT_BRANCH..$DEFAULT_BRANCH" 2>/dev/null || echo "0")
  if [[ "$ahead_count" -gt 0 ]]; then
    error "Local $DEFAULT_BRANCH has $ahead_count unpushed commit(s) ahead of origin/$DEFAULT_BRANCH. Push or reset them before starting new work."
  fi

  if ! git pull --ff-only 2>/dev/null; then
    warn "Could not fast-forward local $DEFAULT_BRANCH to origin/$DEFAULT_BRANCH."
    if [[ -z $(git status --porcelain) ]]; then
      log "Working tree is clean. Safely syncing local $DEFAULT_BRANCH with origin/$DEFAULT_BRANCH..."
      git reset --hard "origin/$DEFAULT_BRANCH"
      success "Local $DEFAULT_BRANCH synced with origin/$DEFAULT_BRANCH."
    else
      error "Working tree has uncommitted changes and local $DEFAULT_BRANCH cannot fast-forward. Stash changes and try again."
    fi
  fi

  local branch_slug
  if [[ -n "$slug_arg" ]]; then
    branch_slug=$(slugify "$slug_arg")
  else
    local cleaned
    cleaned=$(clean_issue_title "$issue_title")
    branch_slug=$(slugify "$cleaned")
  fi

  # Fallback to issue number if slug is empty (e.g. non-ascii/turkish/emoji title)
  branch_slug="${branch_slug:-issue-$issue_no}"

  local branch_name="${BRANCH_PREFIX}${branch_slug}"
  log "Creating branch: $branch_name"
  git switch -c "$branch_name"

  success "Ready to work on issue #$issue_no on branch '$branch_name'!"
  echo ""
  warn "Implement the issue on this branch before running check."
  echo "Next step: write the code/tests for #$issue_no. When done, verify with:"
  echo -e "  ${GREEN}$(resolve_flow_cmd) check${NC}"
}

cmd_check() {
  local cmd
  cmd=$(detect_check_command)
  log "Running verification gate: $cmd"
  eval "$cmd"

  log "Working tree status:"
  git status -sb
  success "Quality gates passed successfully!"
  local branch_issue=""
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || true)
  if [[ "$current_branch" =~ [/-]([0-9]+) ]]; then
    branch_issue="${BASH_REMATCH[1]}"
  fi
  local target_issue="${branch_issue:-<issue_no>}"
  echo ""
  echo "Next step: commit changes and create PR with:"
  echo -e "  ${GREEN}$(resolve_flow_cmd) pr $target_issue \"[title]\"${NC}"
}

cmd_link() {
  local issue_no="${1:-}"
  local pr_no="${2:-}"

  [[ -z "$issue_no" || -z "$pr_no" ]] && error "Usage: $0 link <issue_number> <pr_number>"

  log "Linking PR #$pr_no to Issue #$issue_no..."
  local issue_node_id pr_node_id
  issue_node_id=$(gh issue view "$issue_no" --json id --jq .id 2>/dev/null) || error "Issue #$issue_no not found."
  pr_node_id=$(gh pr view "$pr_no" --json id --jq .id 2>/dev/null) || error "PR #$pr_no not found."

  gh api graphql -f query='
  mutation($issueId: ID!, $pullRequestId: ID!) {
    addCloseIssueReferences(input: {
      issueId: $issueId,
      pullRequestIds: [$pullRequestId]
    }) {
      clientMutationId
    }
  }' -F issueId="$issue_node_id" -F pullRequestId="$pr_node_id" > /dev/null

  success "Linked PR #$pr_no to Issue #$issue_no."
}

cmd_pr() {
  local issue_no="${1:-}"
  local custom_title="${2:-}"
  local custom_body="${3:-}"

  [[ -z "$issue_no" ]] && error "Usage: $0 pr <issue_number> [commit_title] [commit_body]"

  local current_branch
  current_branch=$(git branch --show-current)
  if [[ "$current_branch" == "$DEFAULT_BRANCH" ]]; then
    error "Cannot create PR from default branch '$DEFAULT_BRANCH'. Work on a feature branch."
  fi

  log "Fetching details for issue #$issue_no..."
  local issue_json issue_title
  issue_json=$(gh issue view "$issue_no" --json id,title 2>/dev/null) || error "Issue #$issue_no not found."
  issue_title=$(echo "$issue_json" | jq -r .title)

  local clean_title
  clean_title=$(clean_issue_title "$issue_title")

  if [[ -n $(git status --porcelain) ]]; then
    log "Staging uncommitted changes..."
    git add -A

    local commit_title="${custom_title:-feat: $(echo "$clean_title" | tr '[:upper:]' '[:lower:]') (#$issue_no)}"
    log "Committing changes: $commit_title"
    if [[ -n "$custom_body" ]]; then
      git commit -m "$commit_title" -m "$custom_body"
    else
      git commit -m "$commit_title"
    fi
  else
    log "Working tree clean, using existing commits."
  fi

  log "Pushing branch to origin..."
  git push -u origin HEAD

  local pr_title="${custom_title:-feat: $(echo "$clean_title" | tr '[:upper:]' '[:lower:]') (#$issue_no)}"
  local pr_body
  if [[ -n "$custom_body" ]]; then
    pr_body=$(cat <<EOF
Resolves #$issue_no

### Summary
$custom_body
EOF
)
  else
    pr_body=$(cat <<EOF
Resolves #$issue_no

### Summary
Implementation for #$issue_no ($issue_title).

### Verification
- Quality checks passed cleanly (\`$0 check\`).
EOF
)
  fi

  log "Creating Pull Request..."
  local pr_url pr_no
  pr_url=$(gh pr create --base "$DEFAULT_BRANCH" --title "$pr_title" --body "$pr_body")
  pr_no="${pr_url##*/}"
  if [[ -z "$pr_no" || ! "$pr_no" =~ ^[0-9]+$ ]]; then
    pr_no=$(gh pr view --json number --jq .number 2>/dev/null || true)
  fi
  success "Created PR #$pr_no: $pr_url"

  # Link PR to Issue deterministically
  if [[ -n "$pr_no" ]]; then
    cmd_link "$issue_no" "$pr_no"
  fi

  success "PR #$pr_no prepared and linked successfully!"
  echo ""
  echo "Next step: merge and ship PR with:"
  echo -e "  ${GREEN}$(resolve_flow_cmd) ship $pr_no${NC}"
}

cmd_ship() {
  local pr_no="${1:-}"

  if [[ -z "$pr_no" ]]; then
    pr_no=$(gh pr view --json number --jq .number 2>/dev/null || true)
  fi

  [[ -z "$pr_no" ]] && error "Usage: $0 ship [pr_number] (or run inside branch with open PR)"

  log "Inspecting PR #$pr_no..."
  local pr_json pr_state head_ref linked_issues
  pr_json=$(gh pr view "$pr_no" --json number,title,state,headRefName,closingIssuesReferences)
  pr_state=$(echo "$pr_json" | jq -r .state)
  head_ref=$(echo "$pr_json" | jq -r .headRefName)
  linked_issues=$(echo "$pr_json" | jq -r '(.closingIssuesReferences // [])[].number' 2>/dev/null || true)

  # Fallback: extract issue number from PR title (e.g. "... (#12)") if closingIssuesReferences is empty
  if [[ -z "$linked_issues" ]]; then
    local title_issue
    title_issue=$(echo "$pr_json" | jq -r .title | grep -oE '#[0-9]+' | tr -d '#' | head -n 1 || true)
    if [[ -n "$title_issue" ]]; then
      linked_issues="$title_issue"
    fi
  fi

  if [[ "$pr_state" == "MERGED" ]]; then
    warn "PR #$pr_no is already merged."
  else
    log "Squash-merging PR #$pr_no..."
    gh pr merge "$pr_no" --squash --delete-branch
    success "PR #$pr_no merged and remote branch $head_ref deleted."
  fi

  log "Syncing local $DEFAULT_BRANCH..."
  git switch "$DEFAULT_BRANCH"
  # Prune after --delete-branch so IDE remotes don't keep ghost origin/feature/*
  git fetch --prune origin
  if ! git pull --ff-only 2>/dev/null; then
    warn "Could not fast-forward local $DEFAULT_BRANCH to origin/$DEFAULT_BRANCH (diverged history, common after squash-merge)."
    if [[ -z $(git status --porcelain) ]]; then
      log "Working tree is clean. Safely resetting local $DEFAULT_BRANCH to origin/$DEFAULT_BRANCH..."
      git reset --hard "origin/$DEFAULT_BRANCH"
      success "Local $DEFAULT_BRANCH successfully synced with origin/$DEFAULT_BRANCH."
    else
      error "Working tree has uncommitted changes. Stash or commit them before syncing."
    fi
  fi

  # Clean up local merged feature branch
  if [[ -n "$head_ref" && "$head_ref" != "$DEFAULT_BRANCH" ]]; then
    git branch -D "$head_ref" > /dev/null 2>&1 || true
  fi

  # Sweep every merged branch this PR's merge made deletable (remote + local).
  # Without this, branches merged outside `ship` (GitHub UI, another session)
  # keep their remote branch forever because the early-merge path above skips
  # `--delete-branch`.
  log "Sweeping merged branches..."
  cmd_cleanup

  # Ensure linked issues are closed on GitHub
  if [[ -n "$linked_issues" ]]; then
    for issue_no in $linked_issues; do
      local issue_state
      issue_state=$(gh issue view "$issue_no" --json state --jq .state 2>/dev/null || echo "")
      if [[ "$issue_state" == "OPEN" ]]; then
        gh issue close "$issue_no" --comment "Completed in PR #$pr_no" >/dev/null 2>&1 || true
        success "Closed Issue #$issue_no."
      fi
    done
  fi

  success "Ship completed successfully!"
  echo ""
  echo "Next step: pick up next issue with:"
  echo -e "  ${GREEN}$(resolve_flow_cmd) next${NC}"
}

cmd_next() {
  local auto_start="${1:-}"

  log "Fetching open issues for ${REPO_OWNER}/${REPO_NAME}..."
  local raw_open_issues
  raw_open_issues=$(gh issue list --state open --limit 100 --json number,title,labels 2>/dev/null || true)

  if [[ -z "$raw_open_issues" || "$raw_open_issues" == "[]" ]]; then
    if ! gh auth status >/dev/null 2>&1; then
      error "GitHub CLI authentication or network failure. Run 'gh auth status' to verify."
    fi
    success "No open issues found in ${REPO_OWNER}/${REPO_NAME}! Backlog is clean."
    return 0
  fi

  # Determine reference closed issue (last closed issue / progress watermark)
  local last_closed_no=0
  local raw_closed_issues
  raw_closed_issues=$(gh issue list --state closed --limit 50 --json number,closedAt,stateReason 2>/dev/null || echo "[]")
  if [[ -n "$raw_closed_issues" && "$raw_closed_issues" != "[]" ]]; then
    last_closed_no=$(echo "$raw_closed_issues" | jq -r '
      [ .[] | select(.closedAt != null and .stateReason != "NOT_PLANNED") ] |
      if length == 0 then 0
      else
        (sort_by(.closedAt) | last | .number // 0) as $latest_closed |
        ([ .[].number ] | max // 0) as $max_closed |
        if $max_closed > $latest_closed then $max_closed else $latest_closed end
      end
    ' 2>/dev/null || echo "0")
  fi

  # Sort open issues:
  # 1. Issues with number > last_closed_no, sorted ascending by number
  # 2. Remaining issues (number <= last_closed_no), sorted ascending by number
  local sorted_issues
  sorted_issues=$(echo "$raw_open_issues" | jq --argjson last "$last_closed_no" '
    ([ .[] | select(.number > $last) ] | sort_by(.number)) as $after |
    ([ .[] | select(.number <= $last) ] | sort_by(.number)) as $before |
    $after + $before
  ')

  local count
  count=$(echo "$sorted_issues" | jq '. | length' 2>/dev/null || echo "0")

  if [[ "$last_closed_no" -gt 0 ]]; then
    log "Last closed issue: #$last_closed_no"
  fi

  log "Found $count open issue(s):"
  echo ""
  printf "  ${BLUE}%-7s${NC} %s\n" "ISSUE" "TITLE"
  printf "  %-7s %s\n" "-------" "------------------------------------------------------------"

  echo "$sorted_issues" | jq -r '.[] | "\(.number)\t\(.title)"' | while IFS=$'\t' read -r num title; do
    printf "  #%-6s %s\n" "$num" "$title"
  done
  echo ""

  local next_issue_no next_issue_title
  next_issue_no=$(echo "$sorted_issues" | jq -r '.[0].number')
  next_issue_title=$(echo "$sorted_issues" | jq -r '.[0].title')

  log "Next issue in queue: #${next_issue_no} - ${next_issue_title}"

  if [[ "$auto_start" == "--start" || "$auto_start" == "-s" ]]; then
    log "Auto-starting issue #${next_issue_no}..."
    cmd_start "$next_issue_no"
  else
    echo -e "To start working on this issue, run:"
    echo -e "  ${GREEN}$(resolve_flow_cmd) start ${next_issue_no}${NC}"
  fi
}

cmd_status() {
  log "github-flow Status"
  if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
    echo "Repository: $REPO_OWNER/$REPO_NAME"
  else
    echo "Repository: (unknown remote)"
  fi
  echo "Branch: $(git branch --show-current)"
  local pr_info
  pr_info=$(gh pr view --json number,title,state 2>/dev/null || true)
  if [[ -n "$pr_info" ]]; then
    echo "Active PR: #$(echo "$pr_info" | jq -r .number) - $(echo "$pr_info" | jq -r .title) [$(echo "$pr_info" | jq -r .state)]"
  else
    echo "Active PR: None"
  fi
}

cmd_cleanup() {
  local dry_run="${1:-}"
  local apply="true"
  if [[ "$dry_run" == "--dry-run" || "$dry_run" == "-n" ]]; then
    apply="false"
  fi

  # --- Preflight: refuse to run with an unusable default branch -------------
  # If DEFAULT_BRANCH is empty or does not resolve to a real branch, the name
  # guard cannot protect it and every branch looks deletable. Abort instead.
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    error "DEFAULT_BRANCH is empty — refusing to delete anything. Set DEFAULT_BRANCH in .flowrc or run 'git remote set-head origin -a'."
  fi
  if ! git rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" > /dev/null; then
    error "Default branch '$DEFAULT_BRANCH' does not exist locally — refusing to delete anything."
  fi

  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    warn "Detached HEAD. Switching to '$DEFAULT_BRANCH' first (its branch is never deleted)."
    git switch "$DEFAULT_BRANCH" > /dev/null 2>&1 || error "Could not switch to '$DEFAULT_BRANCH'. Commit or stash changes first."
    current_branch="$DEFAULT_BRANCH"
  elif [[ "$current_branch" != "$DEFAULT_BRANCH" ]]; then
    warn "Currently on '$current_branch'. Switching to '$DEFAULT_BRANCH' first (its branch is never deleted)."
    git switch "$DEFAULT_BRANCH" > /dev/null 2>&1 || error "Could not switch to '$DEFAULT_BRANCH'. Commit or stash changes first."
    current_branch="$DEFAULT_BRANCH"
  fi

  log "Fetching merged/open PR branch names from GitHub..."
  local merged_refs open_refs open_prs
  merged_refs=$(gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null) || error "Could not list merged PRs. Run 'gh auth status' to verify."
  open_prs=$(gh pr list --state open --limit 200 --json headRefName,number --jq '.[] | "\(.headRefName)\t\(.number)"' 2>/dev/null || true)
  open_refs=$(printf '%s\n' "$open_prs" | awk -F'\t' 'NF { print $1 }')

  log "Pruning stale remote tracking refs..."
  git fetch --prune origin > /dev/null 2>&1 || true

  # Remote branches: merged PRs, plus branches whose merge would be a no-op.
  local remote_deleted=0 remote_kept=0
  local remote_branch verdict pr_no
  while IFS= read -r remote_branch; do
    [[ -z "$remote_branch" || "$remote_branch" == "HEAD" ]] && continue
    verdict=$(branch_cleanup_verdict "$remote_branch" "$merged_refs" "$open_refs" "" "origin/$remote_branch")
    # Belt-and-braces: never let a protected name reach a delete call.
    if is_protected_branch_name "$remote_branch"; then
      verdict="default branch"
    fi
    case "$verdict" in
      deletable)
        # A redundant branch may still have an open PR pointing at it. Deleting
        # the branch would close that PR without explanation, so close it first.
        pr_no=$(open_pr_number_for "$remote_branch" "$open_prs")
        if [[ -n "$pr_no" ]]; then
          if [[ "$apply" == "true" ]]; then
            gh pr close "$pr_no" --delete-branch \
              --comment "Closing as redundant: this branch carries no net change over \`$DEFAULT_BRANCH\` (its content already landed via another merged PR). Deleted by \`flow cleanup\`." > /dev/null 2>&1 \
              && success "Closed redundant PR #$pr_no and deleted origin/$remote_branch" \
              || { warn "Could not close redundant PR #$pr_no"; remote_kept=$((remote_kept + 1)); continue; }
          else
            echo "  would close redundant PR #$pr_no and delete remote: origin/$remote_branch"
          fi
        elif [[ "$apply" == "true" ]]; then
          git push origin --delete "$remote_branch" > /dev/null 2>&1 \
            && success "Deleted remote branch: origin/$remote_branch" \
            || { warn "Could not delete remote branch: origin/$remote_branch"; remote_kept=$((remote_kept + 1)); continue; }
        else
          echo "  would delete remote: origin/$remote_branch"
        fi
        remote_deleted=$((remote_deleted + 1))
        ;;
      *)
        echo "  kept remote: origin/$remote_branch ($verdict)"
        remote_kept=$((remote_kept + 1))
        ;;
    esac
  done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/)

  # Local branches: same authority, plus skip the branch we are standing on.
  local local_deleted=0 local_kept=0
  local local_branch
  while IFS= read -r local_branch; do
    [[ -z "$local_branch" ]] && continue
    verdict=$(branch_cleanup_verdict "$local_branch" "$merged_refs" "$open_refs" "$current_branch")
    if is_protected_branch_name "$local_branch"; then
      verdict="default branch"
    fi
    case "$verdict" in
      deletable)
        if [[ "$apply" == "true" ]]; then
          git branch -D "$local_branch" > /dev/null 2>&1 \
            && { success "Deleted local branch: $local_branch"; local_deleted=$((local_deleted + 1)); } \
            || { warn "Could not delete local branch: $local_branch"; local_kept=$((local_kept + 1)); }
        else
          echo "  would delete local: $local_branch"
          local_deleted=$((local_deleted + 1))
        fi
        ;;
      *)
        echo "  kept local: $local_branch ($verdict)"
        local_kept=$((local_kept + 1))
        ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  git fetch --prune origin > /dev/null 2>&1 || true

  echo ""
  if [[ "$apply" == "true" ]]; then
    success "Cleanup done — remote deleted: $remote_deleted, kept: $remote_kept; local deleted: $local_deleted, kept: $local_kept."
  else
    warn "Dry run — remote deletable: $remote_deleted, kept: $remote_kept; local deletable: $local_deleted, kept: $local_kept."
    echo "Re-run without --dry-run to apply."
  fi
}

cmd_help() {
  cat <<EOF
${BOLD}github-flow CLI (scripts/flow.sh)${NC}

Generic GitHub issue and pull request lifecycle automation.

${BOLD}Usage:${NC}
  ./scripts/flow.sh <command> [arguments]

${BOLD}Commands:${NC}
  init                       Wire package.json scripts.flow and create .flowrc (skip if present)
  next [--start]             List open backlog issues and display next candidate (optionally start)
  start <issue_no> [slug]    Start work on an issue (syncs default branch, creates feature branch)
  check                      Run quality gate (auto-detected or configured in .flowrc)
  pr <issue_no> [title]      Commit, push, create PR and link PR to issue
  link <issue_no> <pr_no>    Explicitly link a PR to an issue via GraphQL mutation
  ship [pr_no]               Squash-merge PR, sync default branch, close linked issues, sweep merged branches
  cleanup [--dry-run]        Delete every deletable branch locally and on origin
                             (deletable = merged PR, or merging changes nothing;
                              redundant open PRs are closed first)
  status                     Display repository, branch, and active PR
  help, -h, --help           Show this help message

${BOLD}Lifecycle note:${NC}
  After start, implement the issue on the feature branch (no flow subcommand), then check → pr → ship.

${BOLD}Configuration (.flowrc):${NC}
  Run init once per repo, or copy references/flowrc.example manually.
  Customize CHECK_CMD and branching conventions as needed.

${BOLD}Examples:${NC}
  ./scripts/flow.sh init
  ./scripts/flow.sh next
  ./scripts/flow.sh start 12
  ./scripts/flow.sh check
  ./scripts/flow.sh pr 12 "feat: add health endpoint"
  ./scripts/flow.sh ship 34
EOF
}

# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init)   cmd_init "$@" ;;
    next)   cmd_next "$@" ;;
    start)  cmd_start "$@" ;;
    check)  cmd_check "$@" ;;
    link)   cmd_link "$@" ;;
    pr)     cmd_pr "$@" ;;
    ship)   cmd_ship "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    status) cmd_status "$@" ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command '$cmd'. Run '$0 help' for available commands." ;;
  esac
}

main "$@"
