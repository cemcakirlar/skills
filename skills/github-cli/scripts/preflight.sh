#!/usr/bin/env bash
# Check that git/gh exist and print repo + auth context.
# Usage: bash scripts/preflight.sh [OWNER/REPO]
set -euo pipefail

target="${1:-}"

have() { command -v "$1" >/dev/null 2>&1; }

echo "== binaries =="
if have git; then git --version; else echo "MISSING: git"; fi
if have gh; then gh --version | head -n 1; else echo "MISSING: gh"; fi

echo
echo "== auth =="
if have gh; then
  if ! gh auth status; then
    echo "gh is not authenticated. Run: gh auth login"
  fi
else
  if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    echo "gh missing; GH_TOKEN/GITHUB_TOKEN is set (value hidden)"
  else
    echo "No gh and no GH_TOKEN/GITHUB_TOKEN"
  fi
fi

echo
echo "== git workspace =="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "inside work tree: $(pwd)"
  git remote -v || true
  git status -sb || true
  git branch -vv || true
else
  echo "not inside a git work tree"
fi

echo
echo "== github repo view =="
if have gh; then
  if [[ -n "$target" ]]; then
    gh repo view "$target" --json nameWithOwner,url,isPrivate,defaultBranchRef,viewerPermission
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gh repo view --json nameWithOwner,url,isPrivate,defaultBranchRef,viewerPermission || \
      echo "current directory is not mapped to a GitHub repo gh can see"
  elif [[ -n "${GH_REPO:-}" ]]; then
    gh repo view "$GH_REPO" --json nameWithOwner,url,isPrivate,defaultBranchRef,viewerPermission
  else
    echo "no OWNER/REPO argument, no GH_REPO, no local clone"
  fi
fi
