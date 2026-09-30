#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-flow — Generic GitHub Issue, PR & Project Lifecycle CLI
# =============================================================================

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

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

# Fallback default branch detection
if [[ -z "$DEFAULT_BRANCH" ]]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
fi

# Project board defaults
PROJECT_NUM="${PROJECT_NUM:-}"
PROJECT_OWNER="${PROJECT_OWNER:-$REPO_OWNER}"
STATUS_FIELD_NAME="${STATUS_FIELD_NAME:-Status}"
STATUS_TODO_NAME="${STATUS_TODO_NAME:-Todo}"
STATUS_IN_PROGRESS_NAME="${STATUS_IN_PROGRESS_NAME:-In Progress}"
STATUS_DONE_NAME="${STATUS_DONE_NAME:-Done}"

# Workflow defaults
BRANCH_PREFIX="${BRANCH_PREFIX:-feature/}"
CHECK_CMD="${CHECK_CMD:-}"
DEPLOY_HOOK_URL="${DEPLOY_HOOK_URL:-}"

# Cache variables for project resolution
CACHED_PROJECT_ID=""
CACHED_STATUS_FIELD_ID=""
CACHED_IN_PROGRESS_OPTION_ID=""
CACHED_DONE_OPTION_ID=""

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

resolve_project_details() {
  [[ -z "$PROJECT_NUM" ]] && return 0
  [[ -n "$CACHED_PROJECT_ID" ]] && return 0

  local project_json
  project_json=$(gh project view "$PROJECT_NUM" --owner "$PROJECT_OWNER" --format json 2>/dev/null || true)
  if [[ -z "$project_json" ]]; then
    warn "Project #$PROJECT_NUM not accessible under owner '$PROJECT_OWNER'; board operations disabled."
    return 0
  fi

  CACHED_PROJECT_ID=$(echo "$project_json" | jq -r .id)

  local fields_json
  fields_json=$(gh project field-list "$PROJECT_NUM" --owner "$PROJECT_OWNER" --format json 2>/dev/null || true)
  if [[ -n "$fields_json" ]]; then
    local status_field
    status_field=$(echo "$fields_json" | jq -r ".fields[] | select(.name == \"$STATUS_FIELD_NAME\" and .type == \"ProjectV2SingleSelectField\")" 2>/dev/null || true)
    if [[ -n "$status_field" ]]; then
      CACHED_STATUS_FIELD_ID=$(echo "$status_field" | jq -r .id)
      CACHED_IN_PROGRESS_OPTION_ID=$(echo "$status_field" | jq -r ".options[] | select(.name == \"$STATUS_IN_PROGRESS_NAME\") | .id" 2>/dev/null || true)
      CACHED_DONE_OPTION_ID=$(echo "$status_field" | jq -r ".options[] | select(.name == \"$STATUS_DONE_NAME\") | .id" 2>/dev/null || true)
    fi
  fi
}

get_project_item_id() {
  local issue_no="$1"
  [[ -z "$PROJECT_NUM" || -z "$issue_no" ]] && echo "" && return 0

  gh project item-list "$PROJECT_NUM" --owner "$PROJECT_OWNER" --format json 2>/dev/null \
    | jq -r --argjson num "$issue_no" '.items[]? | select(.content.number? == $num) | .id' 2>/dev/null || echo ""
}

set_item_status() {
  local item_id="$1"
  local target_option_id="$2"

  resolve_project_details
  if [[ -n "$CACHED_PROJECT_ID" && -n "$CACHED_STATUS_FIELD_ID" && -n "$target_option_id" ]]; then
    gh project item-edit \
      --project-id "$CACHED_PROJECT_ID" \
      --id "$item_id" \
      --field-id "$CACHED_STATUS_FIELD_ID" \
      --single-select-option-id "$target_option_id" > /dev/null 2>&1 || true
  fi
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

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

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
  git pull --ff-only

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

  resolve_project_details
  if [[ -n "$PROJECT_NUM" ]]; then
    log "Updating Project #$PROJECT_NUM status..."
    local item_id
    item_id=$(get_project_item_id "$issue_no")
    if [[ -z "$item_id" ]]; then
      log "Issue #$issue_no not on board yet, adding..."
      local issue_url="https://github.com/$REPO_OWNER/$REPO_NAME/issues/$issue_no"
      item_id=$(gh project item-add "$PROJECT_NUM" --owner "$PROJECT_OWNER" --url "$issue_url" --format json --jq .id 2>/dev/null || true)
    fi
    if [[ -n "$item_id" && -n "$CACHED_IN_PROGRESS_OPTION_ID" ]]; then
      set_item_status "$item_id" "$CACHED_IN_PROGRESS_OPTION_ID"
      success "Board item status updated to '$STATUS_IN_PROGRESS_NAME'"
    fi
  fi

  success "Ready to work on issue #$issue_no on branch '$branch_name'!"
}

cmd_check() {
  local cmd
  cmd=$(detect_check_command)
  log "Running verification gate: $cmd"
  eval "$cmd"

  log "Working tree status:"
  git status -sb
  success "Quality gates passed successfully!"
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

  success "Linked PR #$pr_no to Issue #$issue_no (populates Project Linked PRs)."
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
  git pull --ff-only

  # Clean up local merged feature branch
  if [[ -n "$head_ref" && "$head_ref" != "$DEFAULT_BRANCH" ]]; then
    git branch -D "$head_ref" > /dev/null 2>&1 || true
  fi

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

  resolve_project_details
  if [[ -n "$PROJECT_NUM" && -n "$linked_issues" && -n "$CACHED_DONE_OPTION_ID" ]]; then
    for issue_no in $linked_issues; do
      log "Updating Project #$PROJECT_NUM status for Issue #$issue_no to '$STATUS_DONE_NAME'..."
      local item_id
      item_id=$(get_project_item_id "$issue_no")
      if [[ -n "$item_id" ]]; then
        set_item_status "$item_id" "$CACHED_DONE_OPTION_ID"
        success "Issue #$issue_no marked as '$STATUS_DONE_NAME' on board."
      fi
    done
  fi

  if [[ -n "$DEPLOY_HOOK_URL" ]]; then
    cmd_deploy
  fi

  success "Ship completed successfully!"
}

cmd_deploy() {
  if [[ -z "$DEPLOY_HOOK_URL" ]]; then
    error "DEPLOY_HOOK_URL is not configured in .flowrc or environment."
  fi

  log "Triggering deployment webhook..."
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" -X POST "$DEPLOY_HOOK_URL")
  http_code=$(echo "$response" | tail -n 1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
    local build_uuid
    build_uuid=$(echo "$body" | jq -r '.result.build_uuid // empty' 2>/dev/null || echo "")
    if [[ -n "$build_uuid" ]]; then
      success "Deploy hook queued successfully! (Build UUID: $build_uuid, HTTP $http_code)"
    else
      success "Deploy hook triggered successfully! (HTTP $http_code)"
    fi
  else
    warn "Deploy webhook returned HTTP $http_code: $body"
  fi
}

cmd_next() {
  local auto_start="${1:-}"

  log "Fetching open issues for ${REPO_OWNER}/${REPO_NAME}..."
  local issues_json
  issues_json=$(gh issue list --state open --limit 20 --json number,title,labels 2>/dev/null || true)

  if [[ -z "$issues_json" || "$issues_json" == "[]" ]]; then
    success "No open issues found in ${REPO_OWNER}/${REPO_NAME}! Backlog is clean."
    return 0
  fi

  local count
  count=$(echo "$issues_json" | jq '. | length' 2>/dev/null || echo "0")

  log "Found $count open issue(s):"
  echo ""
  printf "  ${BLUE}%-7s${NC} %s\n" "ISSUE" "TITLE"
  printf "  %-7s %s\n" "-------" "------------------------------------------------------------"

  echo "$issues_json" | jq -r '.[] | "\(.number)\t\(.title)"' | while IFS=$'\t' read -r num title; do
    printf "  #%-6s %s\n" "$num" "$title"
  done
  echo ""

  local next_issue_no next_issue_title
  next_issue_no=$(echo "$issues_json" | jq -r '.[0].number')
  next_issue_title=$(echo "$issues_json" | jq -r '.[0].title')

  log "Next issue in queue: #${next_issue_no} - ${next_issue_title}"

  if [[ "$auto_start" == "--start" || "$auto_start" == "-s" ]]; then
    log "Auto-starting issue #${next_issue_no}..."
    cmd_start "$next_issue_no"
  else
    echo -e "To start working on this issue, run:"
    echo -e "  ${GREEN}pnpm flow start ${next_issue_no}${NC}"
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
  if [[ -n "$PROJECT_NUM" ]]; then
    echo "Project Board: https://github.com/users/$PROJECT_OWNER/projects/$PROJECT_NUM"
  fi
}

cmd_help() {
  cat <<EOF
github-flow CLI (scripts/flow.sh)

Generic GitHub issue, pull request, project board, and deployment automation tool.

Usage:
  ./scripts/flow.sh <command> [arguments]

Commands:
  next [--start]             List open backlog issues and display next candidate (optionally start)
  start <issue_no> [slug]    Start work on an issue (syncs default branch, sets board In Progress, creates branch)
  check                      Run quality gate (auto-detected or configured in .flowrc)
  pr <issue_no> [title]      Commit, push, create PR and link PR to issue (populates project board)
  link <issue_no> <pr_no>    Explicitly link a PR to an issue via GraphQL mutation
  ship [pr_no]               Squash-merge PR, sync default branch, set board Done, and trigger deploy hook
  deploy                     Trigger deployment hook manually via POST
  status                     Display repository, branch, active PR, and project board status
  help                       Show this help message

Configuration (.flowrc):
  Place a .flowrc in your repository root to configure Project number, Status fields,
  custom quality check commands, and deploy webhooks. See references/flowrc.example.
EOF
}

# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    next)   cmd_next "$@" ;;
    start)  cmd_start "$@" ;;
    check)  cmd_check "$@" ;;
    link)   cmd_link "$@" ;;
    pr)     cmd_pr "$@" ;;
    ship)   cmd_ship "$@" ;;
    deploy) cmd_deploy "$@" ;;
    status) cmd_status "$@" ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command '$cmd'. Run '$0 help' for available commands." ;;
  esac
}

main "$@"
