# git + gh recipes

Load this file when executing a concrete GitHub task. Commands assume `gh auth` is valid. Replace `OWNER/REPO` and numbers.

## Auth and context

```bash
gh auth status
gh auth setup-git
gh repo view
gh repo view OWNER/REPO --json nameWithOwner,defaultBranchRef,description,isPrivate,url,viewerPermission
git remote -v
git status -sb
git branch -vv
```

Pin repo for subsequent `gh` calls in a script:

```bash
export GH_REPO=OWNER/REPO
```

## Clone, fork, create

```bash
gh repo clone OWNER/REPO
gh repo clone OWNER/REPO dest-dir -- --depth 1          # shallow
gh repo fork OWNER/REPO --clone --remote-name origin
gh repo create NEWNAME --private --source=. --remote=origin --push
gh repo create ORG/NEWNAME --private --description "..."
```

Default visibility for new repos should follow the user. If unspecified, prefer `--private`.

Add upstream on a fork:

```bash
git remote add upstream git@github.com:UPSTREAM/REPO.git
git fetch upstream
```

## Branches

```bash
git fetch origin
git switch -c feature/slug origin/main
git switch main && git pull --ff-only
git switch -
gh pr checkout 42
git branch --show-current
git push -u origin HEAD
git push origin --delete feature/slug                   # after merge, if leftover
```

Create a branch on GitHub without a clone only when necessary; a local branch plus push is clearer for review.

## Commits

```bash
git add -p
git commit -m "Subject"
git commit -m "Subject" -m "Why this change exists."
git log --oneline -20
git diff
git diff --cached
git diff origin/main...HEAD
```

Do not `git add .` when unrelated files are dirty. Do not commit secrets, `.env`, or `node_modules`.

Sync feature branch:

```bash
git fetch origin
git rebase origin/main
# or
git merge origin/main
git push --force-with-lease          # only if this session rebased a branch it owns
```

## Issues

```bash
gh issue list --repo OWNER/REPO --state open
gh issue list --assignee @me --label bug
gh issue view 12
gh issue view 12 --comments
gh issue create --title "..." --body "..." --label bug --assignee @me
gh issue comment 12 --body "..."
gh issue close 12 --reason completed
gh issue reopen 12
gh issue edit 12 --add-label needs-review --remove-label triage
```

Link a PR to an issue with `Fixes #12` in the PR body when the change should close it.

## Pull requests

```bash
gh pr status
gh pr list --state open
gh pr list --author @me --state all
gh pr view 42
gh pr view 42 --comments
gh pr diff 42
gh pr checks 42
gh pr create --title "..." --body "..." --base main --head feature/slug
gh pr create --fill --draft --reviewer alice --reviewer org/team-slug
gh pr ready 42
gh pr review 42 --approve
gh pr review 42 --request-changes --body "..."
gh pr review 42 --comment --body "..."
gh pr checkout 42
gh pr update-branch 42
gh pr merge 42 --squash --delete-branch
gh pr merge 42 --merge
gh pr merge 42 --rebase
gh pr close 42
```

`--fill` uses commit subject/body. Rewrite if the branch has noisy commits.

Request Copilot or human review only when the user wants it.

## Releases and tags

```bash
git tag v1.2.0
git push origin v1.2.0
gh release list
gh release view v1.2.0
gh release create v1.2.0 --generate-notes --title "v1.2.0"
gh release create v1.2.0 ./dist/*.tar.gz --generate-notes
gh release upload v1.2.0 ./artifact.zip
```

Do not move published tags. Do not `--prerelease` unless asked.

## Actions

```bash
gh run list --branch main --limit 10
gh run view 123456789
gh run view 123456789 --log-failed
gh run watch 123456789
gh run rerun 123456789
gh workflow list
gh workflow view ci.yml
gh workflow run ci.yml --ref main
```

`gh run rerun` and `gh workflow run` mutate CI. Confirm on production workflows.

## Search

```bash
gh search repos "org:ORG topic:api language:go"
gh search issues "repo:OWNER/REPO is:open label:bug"
gh search prs "org:ORG is:open review-requested:@me"
gh search commits "repo:OWNER/REPO fix timeout" --author alice
gh search code "func ParseToken" --repo OWNER/REPO --language go
```

Unscoped code/commit search hits all of GitHub and is usually the wrong default. Always add `repo:`, `org:`, or `user:`.

Search uses the `search` rate-limit bucket, not REST `core`. A 403 here is often the per-minute search cap. Check `gh api rate_limit --jq .resources.search` and wait; do not immediately rerun the same query.

## JSON extracts

```bash
gh pr view 42 --json number,title,url,state,isDraft,mergeable,reviews,statusCheckRollup
gh issue list --json number,title,labels,assignees,updatedAt
gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
gh api user --jq .login
```

Prefer explicit `--json` field lists over scraping human tables.

## Cleanup

```bash
git switch main
git pull --ff-only
git branch --merged | grep -v -E '^\*|main|master' | xargs -r git branch -d
git fetch --prune
```

Do not delete unmerged branches unless the user said the work is abandoned.
