#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# github-release — Generic Release, SemVer, Changelog & GitHub Release CLI
# ==============================================================================

# ANSI color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"
cd "$PROJECT_ROOT"

# Defaults
DRY_RUN=false
NO_PUSH=false
SKIP_CHECK=false
SKIP_BUILD=false
ALLOW_DIRTY=false
NOTES_ONLY=false
CREATE_GITHUB_RELEASE=false
ACTION="release"
BUMP_TYPE="patch"
TAG_PREFIX="v"
CHANGELOG_FILE="$PROJECT_ROOT/CHANGELOG.md"
CHECK_CMD=""
BUILD_CMD=""
ASSETS_DIR=""
CUSTOM_ASSETS=()

# Load optional configuration from .releaserc
if [[ -f "$PROJECT_ROOT/.releaserc" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.releaserc"
elif [[ -f "./.releaserc" ]]; then
    # shellcheck source=/dev/null
    source "./.releaserc"
fi

print_help() {
    cat <<EOF
github-release — Automated Semantic Release, Changelog & GitHub Release Orchestrator

Usage:
  ./scripts/release.sh [patch | minor | major | <version> | init] [OPTIONS]

Default release type: patch. Use minor/major only when explicitly intended.

Commands:
  init                   : Initialize repository with .releaserc and CHANGELOG.md

Arguments:
  patch                  : Bump patch version (e.g. 1.0.3 -> 1.0.4) [DEFAULT]
  minor                  : Bump minor version (e.g. 1.0.0 -> 1.1.0)
  major                  : Bump major version (e.g. 1.0.0 -> 2.0.0)
  <X.Y.Z>                : Specify exact SemVer version (e.g. 1.2.0, 2.0.0-rc.1)

Options:
  --github-release, --gh-release : Create and publish a GitHub Release via gh CLI (default: false, tag only)
  --dry-run              : Simulate all steps without modifying files, git, or remote
  --no-push              : Update files, commit and tag locally, but do not push to remote
  --notes-only           : Parse commits and print generated changelog notes to stdout
  --skip-check           : Skip pre-release verification check command
  --skip-build           : Skip build and packaging command
  --allow-dirty          : Allow running with uncommitted git working tree changes
  --tag-prefix <pfx>     : Prefix for git tag (default: "v")
  --help, -h             : Show this help message

Configuration (.releaserc):
  Place a .releaserc file in your repository root to configure verification checks,
  build commands, and release assets.

Examples:
  ./scripts/release.sh init --dry-run
  ./scripts/release.sh init
  ./scripts/release.sh patch --dry-run
  ./scripts/release.sh patch
  ./scripts/release.sh patch --github-release
  ./scripts/release.sh minor
  ./scripts/release.sh 1.2.0 --no-push
  ./scripts/release.sh --notes-only
EOF
}

init_repository() {
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}🛠️  github-release — REPOSITORY INITIALIZATION${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}⚠️  DRY-RUN MODE ACTIVE: No files will be created or modified.${NC}\n"
    fi

    # 1. Detection of package manager and check/build commands
    local check_cmd="pnpm flow check"
    local build_cmd="pnpm build"
    local default_branch="main"
    local tag_prefix="v"

    if [ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]; then
        if grep -q '"flow":' "$PROJECT_ROOT/package.json" 2>/dev/null; then
            check_cmd="pnpm flow check"
        else
            check_cmd="pnpm test"
        fi
        build_cmd="pnpm build"
    elif [ -f "$PROJECT_ROOT/yarn.lock" ]; then
        check_cmd="yarn test"
        build_cmd="yarn build"
    elif [ -f "$PROJECT_ROOT/package-lock.json" ] || [ -f "$PROJECT_ROOT/package.json" ]; then
        check_cmd="npm test"
        build_cmd="npm run build"
    elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
        check_cmd="cargo test"
        build_cmd="cargo build --release"
    elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
        check_cmd="pytest"
        build_cmd="python -m build"
    fi

    # Detect current version
    local initial_version="0.1.0"
    if [ -f "$PROJECT_ROOT/package.json" ] && command -v node > /dev/null 2>&1; then
        initial_version=$(node -e "try { console.log(require('./package.json').version || '0.1.0') } catch(e){ console.log('0.1.0') }" 2>/dev/null || echo "0.1.0")
    elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
        initial_version=$(grep -E '^version\s*=' "$PROJECT_ROOT/Cargo.toml" | head -n1 | sed -E 's/version\s*=\s*"([^"]+)".*/\1/' || echo "0.1.0")
    elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
        initial_version=$(grep -E '^version\s*=' "$PROJECT_ROOT/pyproject.toml" | head -n1 | sed -E 's/version\s*=\s*"([^"]+)".*/\1/' || echo "0.1.0")
    fi

    local releaserc_file="$PROJECT_ROOT/.releaserc"
    local changelog_file="$PROJECT_ROOT/CHANGELOG.md"
    local today
    today=$(date +%Y-%m-%d)

    # Content for .releaserc
    local releaserc_content
    releaserc_content=$(cat <<EOF
# .releaserc — Configuration for github-release

# Verification gate to run before releasing (tests, typecheck, lints)
CHECK_CMD="${check_cmd}"

# Build/compile command to run before tagging
BUILD_CMD="${build_cmd}"

# Target default branch
DEFAULT_BRANCH="${default_branch}"

# Prefix for git tags (e.g. v1.0.0)
TAG_PREFIX="${tag_prefix}"
EOF
)

    # Content for CHANGELOG.md
    local changelog_content
    changelog_content=$(cat <<EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [${initial_version}] - ${today}
### Added
- Initial project release and automated release configuration.
EOF
)

    # Process .releaserc
    echo -e "${BLUE}${BOLD}[1/3] Checking .releaserc...${NC}"
    if [ -f "$releaserc_file" ]; then
        echo -e "   ${GREEN}ℹ️  .releaserc already exists:${NC} $releaserc_file"
    else
        echo -e "   ${CYAN}Creating .releaserc...${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY-RUN] Would create $releaserc_file with content:${NC}"
            echo -e "$releaserc_content" | sed 's/^/     /'
        else
            echo "$releaserc_content" > "$releaserc_file"
            echo -e "   ${GREEN}✅ Created .releaserc${NC}"
        fi
    fi

    # Process CHANGELOG.md
    echo -e "\n${BLUE}${BOLD}[2/3] Checking CHANGELOG.md...${NC}"
    if [ -f "$changelog_file" ]; then
        echo -e "   ${GREEN}ℹ️  CHANGELOG.md already exists:${NC} $changelog_file"
    else
        echo -e "   ${CYAN}Creating CHANGELOG.md...${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY-RUN] Would create $changelog_file with content:${NC}"
            echo -e "$changelog_content" | sed 's/^/     /'
        else
            echo "$changelog_content" > "$changelog_file"
            echo -e "   ${GREEN}✅ Created CHANGELOG.md${NC}"
        fi
    fi

    # Process script permissions & package.json script check
    echo -e "\n${BLUE}${BOLD}[3/3] Checking script permissions and package.json...${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}   [DRY-RUN] Would verify chmod +x on $SCRIPT_DIR/release.sh${NC}"
    else
        chmod +x "$SCRIPT_DIR/release.sh" 2>/dev/null || true
        echo -e "   ${GREEN}✅ Script permissions verified.${NC}"
    fi

    if [ -f "$PROJECT_ROOT/package.json" ]; then
        if grep -q '"release":' "$PROJECT_ROOT/package.json"; then
            echo -e "   ${GREEN}ℹ️  'release' script already configured in package.json.${NC}"
        else
            echo -e "   ${YELLOW}💡 Tip: Add '\"release\": \"bash .agents/skills/github-release/scripts/release.sh\"' to your package.json scripts.${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}🎉 Repository initialization complete!${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "Run without ${BOLD}--dry-run${NC} to apply changes: ${CYAN}pnpm release init${NC}\n"
    else
        echo -e "You can now simulate your first release: ${CYAN}pnpm release patch --dry-run${NC}\n"
    fi
    exit 0
}

# If no arguments provided, show help and exit
if [[ $# -eq 0 ]]; then
    print_help
    exit 0
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        init)
            ACTION="init"
            shift
            ;;
        patch|minor|major)
            BUMP_TYPE="$1"
            shift
            ;;
        --github-release|--gh-release)
            CREATE_GITHUB_RELEASE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-push)
            NO_PUSH=true
            shift
            ;;
        --notes-only)
            NOTES_ONLY=true
            shift
            ;;
        --skip-check)
            SKIP_CHECK=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=true
            shift
            ;;
        --tag-prefix)
            TAG_PREFIX="$2"
            shift 2
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
                BUMP_TYPE="$1"
                shift
            else
                echo -e "${RED}Unknown or invalid parameter: $1${NC}" >&2
                print_help
                exit 1
            fi
            ;;
    esac
done

if [ "$ACTION" = "init" ]; then
    init_repository
fi

# If only notes requested, suppress decorative banners
if [ "$NOTES_ONLY" = false ]; then
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}🚀 github-release — RELEASE ORCHESTRATOR${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

if [ "$DRY_RUN" = true ] && [ "$NOTES_ONLY" = false ]; then
    echo -e "${YELLOW}⚠️  DRY-RUN MODE ACTIVE: No permanent changes will be applied.${NC}\n"
fi

# ==============================================================================
# STEP 1: PREFLIGHT & ENVIRONMENT CHECKS
# ==============================================================================
if [ "$NOTES_ONLY" = false ]; then
    echo -e "${BLUE}${BOLD}[1/7] Environment and Preflight Checks...${NC}"
fi

if ! command -v git > /dev/null 2>&1; then
    echo -e "${RED}❌ Required CLI tool not found: git${NC}" >&2
    exit 1
fi

if [ "$CREATE_GITHUB_RELEASE" = true ] && [ "$NO_PUSH" = false ] && [ "$DRY_RUN" = false ] && [ "$NOTES_ONLY" = false ]; then
    if ! command -v gh > /dev/null 2>&1; then
        echo -e "${RED}❌ Required CLI tool not found: gh (GitHub CLI)${NC}" >&2
        echo -e "   Please install with 'brew install gh' or omit '--github-release'.${NC}"
        exit 1
    fi
    if ! gh auth status > /dev/null 2>&1; then
        echo -e "${RED}❌ 'gh' is not authenticated. Please run 'gh auth login' or omit '--github-release'.${NC}" >&2
        exit 1
    fi
fi

# Git working tree check
if [ "$ALLOW_DIRTY" = false ] && [ "$DRY_RUN" = false ] && [ "$NOTES_ONLY" = false ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${RED}❌ Git working tree has uncommitted changes!${NC}" >&2
        echo -e "   Please commit or stash your changes before releasing." >&2
        echo -e "   (Use '--allow-dirty' or '--dry-run' for testing)" >&2
        exit 1
    fi
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
fi
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH="main"
fi

if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ] && [ "$NOTES_ONLY" = false ]; then
    echo -e "${YELLOW}⚠️  Current branch is '${CURRENT_BRANCH}' (Expected default: '${DEFAULT_BRANCH}').${NC}"
fi

if [ "$NOTES_ONLY" = false ]; then
    echo -e "${GREEN}✅ Environment checks passed.${NC}"
fi

# ==============================================================================
# STEP 2: VERSION CALCULATION (SEMVER & AUTO-DISCOVERY)
# ==============================================================================
if [ "$NOTES_ONLY" = false ]; then
    echo -e "\n${BLUE}${BOLD}[2/7] Semantic Versioning (SemVer)...${NC}"
fi

CURRENT_VERSION=""
MANIFEST_TYPE=""
PBXPROJ_FILE=""

# Detect current project version
if [ -f "$PROJECT_ROOT/package.json" ]; then
    MANIFEST_TYPE="npm"
    if command -v node > /dev/null 2>&1; then
        CURRENT_VERSION=$(node -e "try { console.log(require('./package.json').version || '') } catch(e){}" 2>/dev/null || true)
    fi
    if [ -z "$CURRENT_VERSION" ]; then
        CURRENT_VERSION=$(grep -E '"version":' "$PROJECT_ROOT/package.json" | head -n1 | sed -E 's/.*"version": "([^"]+)".*/\1/' || true)
    fi
elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    MANIFEST_TYPE="cargo"
    CURRENT_VERSION=$(grep -E '^version\s*=' "$PROJECT_ROOT/Cargo.toml" | head -n1 | sed -E 's/version\s*=\s*"([^"]+)".*/\1/' || true)
elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    MANIFEST_TYPE="pyproject"
    CURRENT_VERSION=$(grep -E '^version\s*=' "$PROJECT_ROOT/pyproject.toml" | head -n1 | sed -E 's/version\s*=\s*"([^"]+)".*/\1/' || true)
elif [ -n "$(find "$PROJECT_ROOT" -maxdepth 2 -name "project.pbxproj" 2>/dev/null | head -n1)" ]; then
    MANIFEST_TYPE="xcode"
    PBXPROJ_FILE=$(find "$PROJECT_ROOT" -maxdepth 2 -name "project.pbxproj" | head -n1)
    CURRENT_VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ_FILE" | sed -E 's/.*= ([^;]+);/\1/' | tr -d ' ";' || true)
elif [ -f "$PROJECT_ROOT/VERSION" ]; then
    MANIFEST_TYPE="version_file"
    CURRENT_VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
fi

# Fallback to latest git tag
if [ -z "$CURRENT_VERSION" ]; then
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    if [[ "$LATEST_TAG" =~ ^${TAG_PREFIX}?([0-9]+\.[0-9]+\.[0-9]+.*)$ ]]; then
        CURRENT_VERSION="${BASH_REMATCH[1]}"
    else
        CURRENT_VERSION="0.1.0"
    fi
fi

bump_version() {
    local cur="$1"
    local mode="$2"
    local major minor patch
    local semver_core="${cur%%-*}" # Remove pre-release suffix if present
    IFS="." read -r major minor patch <<< "$semver_core"
    patch=${patch:-0}
    minor=${minor:-0}
    major=${major:-0}

    case "$mode" in
        patch)
            echo "${major}.${minor}.$((patch + 1))"
            ;;
        minor)
            echo "${major}.$((minor + 1)).0"
            ;;
        major)
            echo "$((major + 1)).0.0"
            ;;
        *)
            echo "$mode"
            ;;
    esac
}

NEW_VERSION=$(bump_version "$CURRENT_VERSION" "$BUMP_TYPE")
TAG_NAME="${TAG_PREFIX}${NEW_VERSION}"

if [ "$NOTES_ONLY" = false ]; then
    echo -e "   Current Version : ${BOLD}v${CURRENT_VERSION}${NC} [Detected from: ${MANIFEST_TYPE:-git tag}]"
    echo -e "   New Version     : ${GREEN}${BOLD}${TAG_NAME}${NC}"
fi

# ==============================================================================
# STEP 3: CONVENTIONAL COMMITS & CHANGELOG GENERATION
# ==============================================================================
if [ "$NOTES_ONLY" = false ]; then
    echo -e "\n${BLUE}${BOLD}[3/7] Parsing Conventional Commits & Generating Changelog...${NC}"
fi

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

# If the target tag already exists, find the tag before it
if [ "$PREV_TAG" = "$TAG_NAME" ]; then
    PREV_TAG=$(git describe --tags --abbrev=0 "${TAG_NAME}^" 2>/dev/null || echo "")
fi

LOG_RANGE="HEAD"
if [ -n "$PREV_TAG" ]; then
    LOG_RANGE="${PREV_TAG}..HEAD"
    if [ "$NOTES_ONLY" = false ]; then
        echo -e "   Previous Tag    : ${BOLD}${PREV_TAG}${NC}"
    fi
else
    if [ "$NOTES_ONLY" = false ]; then
        echo -e "   Previous Tag    : ${YELLOW}(Initial release - parsing full git history)${NC}"
    fi
fi

BREAKINGS=()
FEATS=()
FIXES=()
PERFS=()
CHORES=()
OTHERS=()

while IFS='|' read -r subject hash || [ -n "$subject" ]; do
    [ -z "$subject" ] && continue
    case "$subject" in
        chore\(release\)*|"chore: release"*|"Release v"*)
            # Skip automated release commits
            continue
            ;;
        *BREAKING\ CHANGE*|*!:\ *)
            BREAKINGS+=("- ${subject} (\`${hash}\`)")
            ;;
        feat*|Feat*)
            FEATS+=("- ${subject} (\`${hash}\`)")
            ;;
        fix*|Fix*)
            FIXES+=("- ${subject} (\`${hash}\`)")
            ;;
        perf*|refactor*|Perf*|Refactor*)
            PERFS+=("- ${subject} (\`${hash}\`)")
            ;;
        chore*|docs*|build*|ci*|test*|style*|Chore*|Docs*)
            CHORES+=("- ${subject} (\`${hash}\`)")
            ;;
        *)
            OTHERS+=("- ${subject} (\`${hash}\`)")
            ;;
    esac
done < <(git log --pretty=format:"%s|%h" "$LOG_RANGE" 2>/dev/null || true)

TODAY=$(date +%Y-%m-%d)
RELEASE_NOTES="## [${TAG_NAME}] - ${TODAY}\n\n"

if [ ${#BREAKINGS[@]} -gt 0 ]; then
    RELEASE_NOTES+="### ⚠️ Breaking Changes\n"
    for item in "${BREAKINGS[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#FEATS[@]} -gt 0 ]; then
    RELEASE_NOTES+="### Features\n"
    for item in "${FEATS[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#FIXES[@]} -gt 0 ]; then
    RELEASE_NOTES+="### Bug Fixes\n"
    for item in "${FIXES[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#PERFS[@]} -gt 0 ]; then
    RELEASE_NOTES+="### Performance & Refactoring\n"
    for item in "${PERFS[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#CHORES[@]} -gt 0 ]; then
    RELEASE_NOTES+="### Maintenance & Tooling\n"
    for item in "${CHORES[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#OTHERS[@]} -gt 0 ]; then
    RELEASE_NOTES+="### Other Changes\n"
    for item in "${OTHERS[@]}"; do
        RELEASE_NOTES+="${item}\n"
    done
    RELEASE_NOTES+="\n"
fi

if [ ${#BREAKINGS[@]} -eq 0 ] && [ ${#FEATS[@]} -eq 0 ] && [ ${#FIXES[@]} -eq 0 ] && [ ${#PERFS[@]} -eq 0 ] && [ ${#CHORES[@]} -eq 0 ] && [ ${#OTHERS[@]} -eq 0 ]; then
    RELEASE_NOTES+="### Changes\n- Release ${TAG_NAME}\n\n"
fi

# If user only wanted notes, output directly and exit
if [ "$NOTES_ONLY" = true ]; then
    printf "%b" "$RELEASE_NOTES"
    exit 0
fi

BUILD_DIR="$PROJECT_ROOT/.build"
RELEASE_NOTES_FILE="$BUILD_DIR/release-notes-${TAG_NAME}.md"

if [ "$CREATE_GITHUB_RELEASE" = true ] && [ "$DRY_RUN" = false ]; then
    mkdir -p "$BUILD_DIR"
    printf "%b" "$RELEASE_NOTES" > "$RELEASE_NOTES_FILE"
    echo -e "   📄 Release Notes Staged (${RELEASE_NOTES_FILE})"
fi

CHANGELOG_HEADER="# Changelog\n\nAll notable changes to this project will be documented in this file.\nThe format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).\n"

if [ "$DRY_RUN" = false ]; then
    if [ ! -f "$CHANGELOG_FILE" ]; then
        printf "%b\n%b\n" "$CHANGELOG_HEADER" "$RELEASE_NOTES" > "$CHANGELOG_FILE"
    elif ! grep -q "## \[${TAG_NAME}\]" "$CHANGELOG_FILE"; then
        BODY=$(awk 'NR>4' "$CHANGELOG_FILE" 2>/dev/null || cat "$CHANGELOG_FILE")
        printf "%b\n%b\n%s\n" "$CHANGELOG_HEADER" "$RELEASE_NOTES" "$BODY" > "$CHANGELOG_FILE"
    fi
    echo -e "${GREEN}✅ CHANGELOG.md updated.${NC}"
else
    echo -e "${YELLOW}ℹ️  DRY-RUN: CHANGELOG.md update simulated.${NC}"
    echo -e "\n${BOLD}--- Preview of Release Notes ---${NC}"
    printf "%b" "$RELEASE_NOTES"
    echo -e "${BOLD}--------------------------------${NC}\n"
fi

# ==============================================================================
# STEP 4: UPDATE PROJECT MANIFEST METADATA
# ==============================================================================
echo -e "\n${BLUE}${BOLD}[4/7] Updating Project Version Metadata...${NC}"

UPDATED_FILES=("$CHANGELOG_FILE")

case "$MANIFEST_TYPE" in
    npm)
        if [ "$DRY_RUN" = false ]; then
            if command -v npm > /dev/null 2>&1; then
                npm version "$NEW_VERSION" --no-git-tag-version --allow-same-version > /dev/null 2>&1 || {
                    sed -i '' -E "s/\"version\": \"[^\"]+\"/\"version\": \"${NEW_VERSION}\"/" "$PROJECT_ROOT/package.json" 2>/dev/null || \
                    sed -i -E "s/\"version\": \"[^\"]+\"/\"version\": \"${NEW_VERSION}\"/" "$PROJECT_ROOT/package.json"
                }
            else
                sed -i '' -E "s/\"version\": \"[^\"]+\"/\"version\": \"${NEW_VERSION}\"/" "$PROJECT_ROOT/package.json" 2>/dev/null || \
                sed -i -E "s/\"version\": \"[^\"]+\"/\"version\": \"${NEW_VERSION}\"/" "$PROJECT_ROOT/package.json"
            fi
            echo -e "${GREEN}✅ package.json version updated to ${NEW_VERSION}.${NC}"
        else
            echo -e "${YELLOW}ℹ️  DRY-RUN: package.json version update simulated (${NEW_VERSION}).${NC}"
        fi
        UPDATED_FILES+=("$PROJECT_ROOT/package.json")
        ;;
    cargo)
        if [ "$DRY_RUN" = false ]; then
            sed -i '' -E "s/^version = \"[^\"]+\"/version = \"${NEW_VERSION}\"/" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null || \
            sed -i -E "s/^version = \"[^\"]+\"/version = \"${NEW_VERSION}\"/" "$PROJECT_ROOT/Cargo.toml"
            echo -e "${GREEN}✅ Cargo.toml version updated to ${NEW_VERSION}.${NC}"
        else
            echo -e "${YELLOW}ℹ️  DRY-RUN: Cargo.toml version update simulated (${NEW_VERSION}).${NC}"
        fi
        UPDATED_FILES+=("$PROJECT_ROOT/Cargo.toml")
        ;;
    pyproject)
        if [ "$DRY_RUN" = false ]; then
            sed -i '' -E "s/^version = \"[^\"]+\"/version = \"${NEW_VERSION}\"/" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null || \
            sed -i -E "s/^version = \"[^\"]+\"/version = \"${NEW_VERSION}\"/" "$PROJECT_ROOT/pyproject.toml"
            echo -e "${GREEN}✅ pyproject.toml version updated to ${NEW_VERSION}.${NC}"
        else
            echo -e "${YELLOW}ℹ️  DRY-RUN: pyproject.toml version update simulated (${NEW_VERSION}).${NC}"
        fi
        UPDATED_FILES+=("$PROJECT_ROOT/pyproject.toml")
        ;;
    xcode)
        if [ "$DRY_RUN" = false ]; then
            CURRENT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ_FILE" | sed -E 's/.*= ([^;]+);/\1/' | tr -d ' ";' || echo "1")
            NEW_BUILD=$((CURRENT_BUILD + 1))
            sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${NEW_VERSION};/g" "$PBXPROJ_FILE"
            sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBXPROJ_FILE"
            echo -e "${GREEN}✅ $PBXPROJ_FILE updated (VERSION: $NEW_VERSION, BUILD: $NEW_BUILD).${NC}"
        else
            echo -e "${YELLOW}ℹ️  DRY-RUN: $PBXPROJ_FILE version update simulated (${NEW_VERSION}).${NC}"
        fi
        UPDATED_FILES+=("$PBXPROJ_FILE")
        ;;
    version_file)
        if [ "$DRY_RUN" = false ]; then
            echo "$NEW_VERSION" > "$PROJECT_ROOT/VERSION"
            echo -e "${GREEN}✅ VERSION file updated to ${NEW_VERSION}.${NC}"
        else
            echo -e "${YELLOW}ℹ️  DRY-RUN: VERSION file update simulated (${NEW_VERSION}).${NC}"
        fi
        UPDATED_FILES+=("$PROJECT_ROOT/VERSION")
        ;;
    *)
        echo -e "${YELLOW}ℹ️  No project manifest detected; version will be tracked via git tag only.${NC}"
        ;;
esac

# ==============================================================================
# STEP 5: PRE-RELEASE VERIFICATION & BUILD HOOKS
# ==============================================================================
echo -e "\n${BLUE}${BOLD}[5/7] Verification and Build Hooks...${NC}"

# 1. Quality Check Command
if [ "$SKIP_CHECK" = false ] && [ -n "$CHECK_CMD" ]; then
    if [ "$DRY_RUN" = false ]; then
        echo -e "${BLUE}Running quality check: ${BOLD}${CHECK_CMD}${NC}"
        eval "$CHECK_CMD"
        echo -e "${GREEN}✅ Quality checks passed.${NC}"
    else
        echo -e "${YELLOW}ℹ️  DRY-RUN: Quality check simulated (${CHECK_CMD}).${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  Verification checks skipped or not configured.${NC}"
fi

# 2. Build / Package Command
if [ "$SKIP_BUILD" = false ] && [ -n "$BUILD_CMD" ]; then
    if [ "$DRY_RUN" = false ]; then
        echo -e "${BLUE}Running build command: ${BOLD}${BUILD_CMD}${NC}"
        eval "$BUILD_CMD"
        echo -e "${GREEN}✅ Build command succeeded.${NC}"
    else
        echo -e "${YELLOW}ℹ️  DRY-RUN: Build command simulated (${BUILD_CMD}).${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  Build step skipped or not configured.${NC}"
fi

# ==============================================================================
# STEP 6: GIT COMMIT AND ANNOTATED TAG
# ==============================================================================
echo -e "\n${BLUE}${BOLD}[6/7] Creating Git Commit and Annotated Tag...${NC}"

COMMIT_MSG="chore(release): ${TAG_NAME}"

if [ "$DRY_RUN" = false ]; then
    for f in "${UPDATED_FILES[@]}"; do
        if [ -f "$f" ]; then
            git add "$f"
        fi
    done
    git commit -m "$COMMIT_MSG" || true
    echo -e "   ✅ Commit created: ${BOLD}${COMMIT_MSG}${NC}"

    if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Tag ${TAG_NAME} already exists locally, updating...${NC}"
        git tag -d "$TAG_NAME" > /dev/null 2>&1 || true
    fi
    git tag -a "$TAG_NAME" -m "Release ${TAG_NAME}"
    echo -e "${GREEN}✅ Git tag created: ${BOLD}${TAG_NAME}${NC}"
else
    echo -e "${YELLOW}ℹ️  DRY-RUN: 'git commit -m \"${COMMIT_MSG}\"' and 'git tag -a ${TAG_NAME}' simulated.${NC}"
fi

# ==============================================================================
# STEP 7: PUSH AND GITHUB RELEASE
# ==============================================================================
echo -e "\n${BLUE}${BOLD}[7/7] Git Push and GitHub Release...${NC}"

if [ "$NO_PUSH" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "${BLUE}📤 Pushing branch '${CURRENT_BRANCH}' and tag '${TAG_NAME}' to origin...${NC}"
    git push origin "$CURRENT_BRANCH"
    git push origin "$TAG_NAME"
    echo -e "${GREEN}✅ Git push completed.${NC}"

    if [ "$CREATE_GITHUB_RELEASE" = true ]; then
        if command -v gh > /dev/null 2>&1; then
            echo -e "${BLUE}🚀 Publishing GitHub Release via gh CLI...${NC}"

            RELEASE_ARGS=()
            if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR" ]; then
                for asset in "$ASSETS_DIR"/*; do
                    if [ -f "$asset" ]; then
                        RELEASE_ARGS+=("$asset")
                    fi
                done
            fi
            if [ ${#CUSTOM_ASSETS[@]} -gt 0 ]; then
                for asset in "${CUSTOM_ASSETS[@]}"; do
                    if [ -f "$asset" ]; then
                        RELEASE_ARGS+=("$asset")
                    fi
                done
            fi

            if gh release view "$TAG_NAME" > /dev/null 2>&1; then
                echo -e "${YELLOW}ℹ️  Updating existing GitHub release...${NC}"
                gh release edit "$TAG_NAME" --title "${TAG_NAME}" --notes-file "$RELEASE_NOTES_FILE"
                if [ ${#RELEASE_ARGS[@]} -gt 0 ]; then
                    gh release upload "$TAG_NAME" "${RELEASE_ARGS[@]}" --clobber
                fi
            else
                gh release create "$TAG_NAME" \
                    "${RELEASE_ARGS[@]}" \
                    --title "${TAG_NAME}" \
                    --notes-file "$RELEASE_NOTES_FILE"
            fi

            echo -e "${GREEN}✅ GitHub Release created successfully: ${BOLD}${TAG_NAME}${NC}"
            gh release view "$TAG_NAME" --web 2>/dev/null || true
        else
            echo -e "${RED}❌ 'gh' CLI not found. GitHub Release skipped.${NC}" >&2
        fi
    else
        echo -e "${CYAN}ℹ️  Git tag pushed. GitHub Release creation skipped (pass '--github-release' to create).${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  Git push skipped due to --no-push or --dry-run.${NC}"
    if [ "$DRY_RUN" = true ]; then
        if [ "$CREATE_GITHUB_RELEASE" = true ]; then
            echo -e "${YELLOW}ℹ️  DRY-RUN: Git push and GitHub Release creation simulated for ${TAG_NAME}.${NC}"
        else
            echo -e "${CYAN}ℹ️  DRY-RUN: Git push simulated. GitHub Release creation skipped (pass '--github-release' to enable).${NC}"
        fi
    elif [ "$DRY_RUN" = false ]; then
        echo -e "   To push manually:"
        echo -e "     git push origin ${CURRENT_BRANCH} && git push origin ${TAG_NAME}"
        if [ "$CREATE_GITHUB_RELEASE" = true ]; then
            echo -e "     gh release create ${TAG_NAME} --title \"${TAG_NAME}\" --notes-file \"${RELEASE_NOTES_FILE}\""
        fi
    fi
fi

if [ "$NOTES_ONLY" = false ]; then
    echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}🎉 RELEASE CYCLE FINISHED: ${TAG_NAME}${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "   🏷️  Tag       : ${TAG_NAME}"
    echo -e "   📄 Changelog : ${CHANGELOG_FILE}"
    echo ""
fi
