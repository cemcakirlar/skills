#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# skills-upstream — Inspect and batch-sync local skill edits to upstream repos
# =============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log()     { echo -e "${BLUE}==>${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}!${NC} $*" >&2; }
error()   { echo -e "${RED}✗ Error:${NC} $*" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CURRENT_REPO_NAME=$(basename "$REPO_ROOT")

UPSTREAM_CLONE_DIR=""
cleanup_clone() {
  if [[ -n "${UPSTREAM_CLONE_DIR:-}" && -d "${UPSTREAM_CLONE_DIR:-}" ]]; then
    rm -rf "$UPSTREAM_CLONE_DIR"
  fi
}
trap cleanup_clone EXIT INT TERM

# -----------------------------------------------------------------------------
# Help / Usage
# -----------------------------------------------------------------------------
show_help() {
  cat <<EOF
${BOLD}skills-upstream CLI (scripts/upstream.sh)${NC}

Inspect drift and batch-sync local skill refinements to upstream repositories.

${BOLD}Usage:${NC}
  ./scripts/upstream.sh [command] [options]

${BOLD}Commands:${NC}
  status, check         Display drift status table across installed skills
  diff                  Show unified diff for modified skills against upstream
  pr [title] [body]     Batch-commit modified skills and open an upstream PR
  sources               List all upstream sources found in the lockfile
  help, -h, --help      Show this help message

${BOLD}Options:${NC}
  -s, --source <repo>   Target specific upstream repository (e.g. cemcakirlar/skills)
  -k, --skill <name>    Target a specific skill only (e.g. github-flow)
  -y, --yes             Auto-confirm PR creation without interactive prompt
  -l, --lock <path>     Path to skills lockfile (default: auto-detected)
  -g, --global          Use global skills lockfile (~/.agents/.skill-lock.json)

${BOLD}Examples:${NC}
  ./scripts/upstream.sh status
  ./scripts/upstream.sh status --source cemcakirlar/skills
  ./scripts/upstream.sh diff --skill github-flow
  ./scripts/upstream.sh pr --source cemcakirlar/skills --skill github-flow "feat: enhance flow"
EOF
}

# Check for help command immediately before any lockfile check
for arg in "$@"; do
  if [[ "$arg" == "help" || "$arg" == "-h" || "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
done

# -----------------------------------------------------------------------------
# Options and Arguments Parsing
# -----------------------------------------------------------------------------
COMMAND=""
TARGET_SOURCE="${UPSTREAM_SOURCE:-}"
TARGET_SKILL=""
LOCK_FILE_OVERRIDE=""
IS_GLOBAL=false
AUTO_CONFIRM=false
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    status|check|diff|pr|sources)
      COMMAND="$1"
      shift
      ;;
    -s|--source)
      [[ -z "${2:-}" ]] && error "Option -s/--source requires an argument."
      TARGET_SOURCE="$2"
      shift 2
      ;;
    -k|--skill)
      [[ -z "${2:-}" ]] && error "Option -k/--skill requires an argument."
      TARGET_SKILL="$2"
      shift 2
      ;;
    -y|--yes)
      AUTO_CONFIRM=true
      shift
      ;;
    -l|--lock)
      [[ -z "${2:-}" ]] && error "Option -l/--lock requires an argument."
      LOCK_FILE_OVERRIDE="$2"
      shift 2
      ;;
    -g|--global)
      IS_GLOBAL=true
      shift
      ;;
    help|-h|--help)
      show_help
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

COMMAND="${COMMAND:-status}"

# -----------------------------------------------------------------------------
# Lockfile & Environment Resolution
# -----------------------------------------------------------------------------
find_lock_file() {
  if [[ -n "$LOCK_FILE_OVERRIDE" ]]; then
    if [[ -f "$LOCK_FILE_OVERRIDE" ]]; then
      echo "$LOCK_FILE_OVERRIDE"
      return 0
    else
      error "Specified lockfile not found: $LOCK_FILE_OVERRIDE"
    fi
  fi

  if [[ "$IS_GLOBAL" == "true" ]]; then
    local global_lock="$HOME/.agents/.skill-lock.json"
    if [[ -f "$global_lock" ]]; then
      echo "$global_lock"
      return 0
    else
      error "Global lockfile not found at $global_lock"
    fi
  fi

  # Auto-detect local project lockfile
  local candidates=(
    "$REPO_ROOT/skills-lock.json"
    "$REPO_ROOT/.skill-lock.json"
    "$REPO_ROOT/.agents/.skill-lock.json"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  # Fallback to global lockfile if present
  if [[ -f "$HOME/.agents/.skill-lock.json" ]]; then
    echo "$HOME/.agents/.skill-lock.json"
    return 0
  fi

  error "No skills lockfile found in $REPO_ROOT or ~/.agents/.
Run 'npx skills add <source> --skill <name>' first, or specify lockfile with -l <path>."
}

LOCK_FILE=$(find_lock_file)

if ! command -v jq >/dev/null 2>&1; then
  error "'jq' is required to parse skills lockfiles. Please install jq."
fi

get_all_sources() {
  jq -r '.skills | to_entries[].value.source // empty' "$LOCK_FILE" 2>/dev/null | sort -u
}

get_source_skills() {
  local src="$1"
  if [[ -n "$TARGET_SKILL" ]]; then
    jq -r --arg s "$src" --arg k "$TARGET_SKILL" '
      .skills | to_entries[] | select(.value.source == $s and .key == $k) | .key
    ' "$LOCK_FILE" 2>/dev/null
  else
    jq -r --arg s "$src" '
      .skills | to_entries[] | select(.value.source == $s) | .key
    ' "$LOCK_FILE" 2>/dev/null
  fi
}

find_local_skill_dir() {
  local skill="$1"
  local candidates=(
    "$REPO_ROOT/.agents/skills/$skill"
    "$REPO_ROOT/.claude/skills/$skill"
    "$REPO_ROOT/.cursor/skills/$skill"
    "$REPO_ROOT/.gemini/skills/$skill"
    "$REPO_ROOT/.windsurf/skills/$skill"
    "$REPO_ROOT/skills/$skill"
  )

  if [[ "$IS_GLOBAL" == "true" || "$LOCK_FILE" == "$HOME/.agents/.skill-lock.json" ]]; then
    candidates=(
      "$HOME/.agents/skills/$skill"
      "${candidates[@]}"
    )
  fi

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

get_upstream_skill_dir() {
  local skill="$1"
  local upstream_dir="$2"

  local skill_path
  skill_path=$(jq -r --arg s "$skill" '.skills[$s].skillPath // empty' "$LOCK_FILE" 2>/dev/null || true)

  if [[ -n "$skill_path" && "$skill_path" != "null" ]]; then
    local rel_dir
    rel_dir=$(dirname "$skill_path")
    if [[ "$rel_dir" == "." ]]; then
      echo "$upstream_dir"
      return 0
    else
      echo "$upstream_dir/$rel_dir"
      return 0
    fi
  fi

  if [[ -d "$upstream_dir/skills/$skill" ]]; then
    echo "$upstream_dir/skills/$skill"
  elif [[ -d "$upstream_dir/$skill" ]]; then
    echo "$upstream_dir/$skill"
  else
    echo "$upstream_dir/skills/$skill"
  fi
}

ensure_upstream_clone() {
  local src="$1"
  if [[ -z "$UPSTREAM_CLONE_DIR" || ! -d "$UPSTREAM_CLONE_DIR" ]]; then
    UPSTREAM_CLONE_DIR=$(mktemp -d)
  fi
  local safe_dir_name
  safe_dir_name=$(echo "$src" | tr '/:' '__')
  local target_dir="$UPSTREAM_CLONE_DIR/$safe_dir_name"

  if [[ -d "$target_dir/.git" ]]; then
    echo "$target_dir"
    return 0
  fi

  mkdir -p "$UPSTREAM_CLONE_DIR"
  log "Fetching upstream repository ($src)..."

  local clone_url
  if [[ "$src" == /* || "$src" == ./* || "$src" == file://* ]]; then
    clone_url="$src"
  else
    clone_url="https://github.com/$src.git"
  fi

  local clone_err
  clone_err=$(mktemp)
  if ! git clone --depth 1 "$clone_url" "$target_dir" >/dev/null 2>"$clone_err"; then
    local err_msg
    err_msg=$(cat "$clone_err")
    rm -f "$clone_err"
    error "Failed to clone $clone_url:
$err_msg"
  fi
  rm -f "$clone_err"
  echo "$target_dir"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_sources() {
  log "Upstream sources detected in $LOCK_FILE:"
  echo ""
  local sources=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sources+=("$line")
  done < <(get_all_sources)

  if [[ ${#sources[@]} -eq 0 ]]; then
    warn "No upstream sources found in $LOCK_FILE."
    return 0
  fi

  for src in "${sources[@]}"; do
    local count
    count=$(jq -r --arg s "$src" '[.skills[] | select(.source == $s)] | length' "$LOCK_FILE")
    printf "  • ${BOLD}%-35s${NC} (%d skill%s)\n" "$src" "$count" "$( [[ $count -gt 1 ]] && echo 's' || echo '' )"
  done
  echo ""
}

inspect_source_status() {
  local src="$1"
  local upstream_dir
  upstream_dir=$(ensure_upstream_clone "$src")

  log "Inspecting skill drift against ${BOLD}$src${NC}:"
  echo ""
  printf "  ${BOLD}%-24s %-14s %s${NC}\n" "Skill" "Status" "Details"
  printf "  %-24s %-14s %s\n" "------------------------" "--------------" "---------------------------"

  local changed_count=0
  local total_count=0

  for skill in $(get_source_skills "$src"); do
    total_count=$((total_count + 1))
    local local_skill_dir
    local_skill_dir=$(find_local_skill_dir "$skill" || true)

    if [[ -z "$local_skill_dir" || ! -d "$local_skill_dir" ]]; then
      printf "  %-24s ${YELLOW}%-14s${NC} %s\n" "$skill" "Missing local" "Folder not found in local agent directories"
      continue
    fi

    local upstream_skill_dir
    upstream_skill_dir=$(get_upstream_skill_dir "$skill" "$upstream_dir")

    if [[ ! -d "$upstream_skill_dir" ]]; then
      printf "  %-24s ${YELLOW}%-14s${NC} %s\n" "$skill" "New local" "Directory not in upstream"
      changed_count=$((changed_count + 1))
      continue
    fi

    local diff_stat
    diff_stat=$(diff -ru -x ".DS_Store" -x "node_modules" -x ".git" "$upstream_skill_dir" "$local_skill_dir" 2>/dev/null || true)

    if [[ -z "$diff_stat" ]]; then
      printf "  %-24s ${GREEN}%-14s${NC} %s\n" "$skill" "✓ In sync" "Identical to upstream"
    else
      local changed_files
      changed_files=$( (diff -r -q -x ".DS_Store" -x "node_modules" -x ".git" "$upstream_skill_dir" "$local_skill_dir" 2>/dev/null || true) | wc -l | tr -d ' ')
      printf "  %-24s ${YELLOW}%-14s${NC} %s\n" "$skill" "! Modified" "$changed_files file(s) differ from upstream"
      changed_count=$((changed_count + 1))
    fi
  done

  echo ""
  if [[ $changed_count -gt 0 ]]; then
    warn "$changed_count of $total_count skill(s) in $src have local improvements pending sync."
    echo -e "  Run diff command to view unified diff."
    echo -e "  Run pr command to open a consolidated upstream PR."
  else
    success "All $total_count skills for $src are completely in sync!"
  fi
  echo ""
}

cmd_status() {
  local sources=()
  if [[ -n "$TARGET_SOURCE" ]]; then
    sources=("$TARGET_SOURCE")
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && sources+=("$line")
    done < <(get_all_sources)
  fi

  [[ ${#sources[@]} -eq 0 ]] && error "No upstream sources found in $LOCK_FILE."

  for src in "${sources[@]}"; do
    inspect_source_status "$src"
  done
}

inspect_source_diff() {
  local src="$1"
  local upstream_dir
  upstream_dir=$(ensure_upstream_clone "$src")

  log "Displaying unified diff against ${BOLD}$src${NC}:"
  local has_diff=0

  for skill in $(get_source_skills "$src"); do
    local local_skill_dir
    local_skill_dir=$(find_local_skill_dir "$skill" || true)
    [[ -z "$local_skill_dir" || ! -d "$local_skill_dir" ]] && continue

    local upstream_skill_dir
    upstream_skill_dir=$(get_upstream_skill_dir "$skill" "$upstream_dir")
    [[ ! -d "$upstream_skill_dir" ]] && continue

    local diff_out
    diff_out=$(diff -ru --color=always -x ".DS_Store" -x "node_modules" -x ".git" "$upstream_skill_dir" "$local_skill_dir" 2>/dev/null || true)

    if [[ -n "$diff_out" ]]; then
      has_diff=1
      echo ""
      echo -e "${BOLD}=== Skill: $skill (Source: $src) ===${NC}"
      echo "$diff_out"
    fi
  done

  if [[ $has_diff -eq 0 ]]; then
    success "No differences found for $src. All skills are in sync."
  fi
  echo ""
}

cmd_diff() {
  local sources=()
  if [[ -n "$TARGET_SOURCE" ]]; then
    sources=("$TARGET_SOURCE")
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && sources+=("$line")
    done < <(get_all_sources)
  fi

  [[ ${#sources[@]} -eq 0 ]] && error "No upstream sources found in $LOCK_FILE."

  for src in "${sources[@]}"; do
    inspect_source_diff "$src"
  done
}

cmd_pr() {
  local custom_title="${EXTRA_ARGS[0]:-}"
  local custom_body="${EXTRA_ARGS[1]:-}"

  if [[ -z "$TARGET_SOURCE" ]]; then
    local available_sources=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && available_sources+=("$line")
    done < <(get_all_sources)

    warn "Creating an upstream Pull Request requires explicitly targeting the repository."
    echo ""
    echo -e "  ${BOLD}Available sources in lockfile:${NC}"
    for s in "${available_sources[@]}"; do
      echo -e "    • $s"
    done
    echo ""
    error "Please specify target repository with: --source <owner/repo>"
  fi

  local src="$TARGET_SOURCE"
  local upstream_dir
  upstream_dir=$(ensure_upstream_clone "$src")

  log "Collecting modified skills for $src..."
  local changed_skills=()

  for skill in $(get_source_skills "$src"); do
    local local_skill_dir
    local_skill_dir=$(find_local_skill_dir "$skill" || true)
    [[ -z "$local_skill_dir" || ! -d "$local_skill_dir" ]] && continue

    local upstream_skill_dir
    upstream_skill_dir=$(get_upstream_skill_dir "$skill" "$upstream_dir")

    local diff_stat
    diff_stat=$(diff -ru -x ".DS_Store" -x "node_modules" -x ".git" "$upstream_skill_dir" "$local_skill_dir" 2>/dev/null || true)

    if [[ -n "$diff_stat" ]]; then
      changed_skills+=("$skill")
      mkdir -p "$upstream_skill_dir"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude='.DS_Store' --exclude='node_modules' --exclude='.git' "$local_skill_dir/" "$upstream_skill_dir/"
      else
        cp -R "$local_skill_dir/"* "$upstream_skill_dir/"
      fi
    fi
  done

  if [[ ${#changed_skills[@]} -eq 0 ]]; then
    success "All skills are already in sync with $src. Nothing to PR!"
    return 0
  fi

  log "Found changes in ${#changed_skills[@]} skill(s): ${changed_skills[*]}"

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local branch_name="sync/${CURRENT_REPO_NAME}-${timestamp}"
  local pr_title="${custom_title:-feat(skills): sync improvements from ${CURRENT_REPO_NAME}}"

  echo ""
  echo -e "${BOLD}Pull Request Plan:${NC}"
  echo -e "  Target Upstream : ${BLUE}$src${NC}"
  echo -e "  Skills to Sync  : ${GREEN}${changed_skills[*]}${NC}"
  echo -e "  Branch Name     : $branch_name"
  echo -e "  PR Title        : $pr_title"
  echo ""

  if [[ "$AUTO_CONFIRM" != "true" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Proceed with pushing branch and opening Pull Request on $src? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warn "Aborted by user. No branches were pushed to $src."
        return 0
      fi
    else
      warn "Non-interactive environment detected. Use -y / --yes to confirm PR creation."
      error "PR creation aborted: explicit confirmation required before pushing to upstream repository ($src)."
    fi
  fi

  cd "$upstream_dir"
  git checkout -b "$branch_name" >/dev/null 2>&1
  git add -A

  log "Committing changes to branch '$branch_name'..."
  git commit -m "$pr_title" >/dev/null

  log "Pushing branch '$branch_name' to upstream..."
  local push_err
  push_err=$(mktemp)

  if ! git push -u origin "$branch_name" 2>"$push_err"; then
    local err_content
    err_content=$(cat "$push_err")
    rm -f "$push_err"

    if echo "$err_content" | grep -qiE "permission to|denied|403|not permitted"; then
      warn "Direct push to $src failed with permission error. Attempting fork workflow..."
      if ! command -v gh >/dev/null 2>&1; then
        error "Direct push failed and GitHub CLI ('gh') is not installed.
Push error: $err_content"
      fi

      local gh_user
      gh_user=$(gh api user -q .login 2>/dev/null || true)
      if [[ -z "$gh_user" ]]; then
        error "GitHub CLI authentication missing. Run 'gh auth login' to authenticate."
      fi

      log "Forking $src (or using existing fork under @$gh_user)..."
      gh repo fork "$src" --remote=true --clone=false 2>/dev/null || true

      local fork_remote="origin"
      if git remote | grep -q "^fork$"; then
        fork_remote="fork"
      else
        git remote add fork "https://github.com/$gh_user/$(basename "$src").git" 2>/dev/null || true
        fork_remote="fork"
      fi

      log "Pushing branch to fork remote '$fork_remote'..."
      if ! git push -u "$fork_remote" "$branch_name"; then
        error "Failed to push branch to fork remote '$fork_remote'."
      fi
      success "Branch pushed to fork successfully."
    else
      error "Git push failed:
$err_content"
    fi
  else
    rm -f "$push_err"
    success "Branch pushed to origin successfully."
  fi

  log "Opening Pull Request against $src..."

  local pr_body
  if [[ -n "$custom_body" ]]; then
    pr_body="$custom_body"
  else
    pr_body=$(cat <<EOF
### Summary
This PR synchronizes generic skill refinements developed and tested inside the **\`${CURRENT_REPO_NAME}\`** project.

### Skills Included
$(printf -- '- `%s`\n' "${changed_skills[@]}")

### Verification
- Tested and verified in local project workflow inside \`${CURRENT_REPO_NAME}\`.
EOF
)
  fi

  local head_arg="$branch_name"
  if git remote | grep -q "^fork$" && [[ -n "${gh_user:-}" ]]; then
    head_arg="${gh_user}:${branch_name}"
  fi

  local pr_url
  pr_url=$(gh pr create --repo "$src" --head "$head_arg" --title "$pr_title" --body "$pr_body")
  success "Upstream PR opened successfully: $pr_url"
}

# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
case "$COMMAND" in
  status|check) cmd_status ;;
  diff)         cmd_diff ;;
  pr)           cmd_pr ;;
  sources)      cmd_sources ;;
  *) error "Unknown command '$COMMAND'. Run './scripts/upstream.sh help' for usage." ;;
esac
