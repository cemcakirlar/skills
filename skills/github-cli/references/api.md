# gh api escape hatch

Use `gh api` when no first-class `gh` command exposes the needed field or action. `gh` injects the authenticated token, correct API host, and preview headers. Prefer it over raw `curl`.

## Invocation basics

```bash
gh api user
gh api repos/OWNER/REPO
gh api repos/OWNER/REPO/commits --jq '.[].sha'
gh api --method POST repos/OWNER/REPO/issues -f title='Bug' -f body='Steps'
gh api --method PATCH repos/OWNER/REPO/issues/12 -f state=closed
gh api --method DELETE repos/OWNER/REPO/contents/PATH   # still needs sha + message; prefer git
```

Flags that matter:

| Flag | Role |
|---|---|
| `--method GET\|POST\|PATCH\|PUT\|DELETE` | HTTP verb (GET is default) |
| `-f key=value` | form/string field |
| `-F key=@file` | file or typed field |
| `--input -` or `--input file.json` | raw JSON body |
| `--jq 'expr'` | jq filter on the response |
| `--paginate` | follow Link pages |
| `--slurp` | combine paginated arrays |
| `--silent` | no response body |
| `--hostname github.example.com` | GHE / non-default host |
| `--header "X-GitHub-Api-Version: …"` | Pin REST API version (see below) |
| `--preview NAME` | extra Accept preview (rare now) |

## REST API version

Pin `X-GitHub-Api-Version` on every raw REST call. Do not rely on the implicit default.

On github.com the current version is `2026-03-10`. Requests that omit the header still default to `2022-11-28`. That older version remains supported until 2028-03-10; new work should not target it.

Confirm what the host actually serves before copying a date from memory:

```bash
gh api versions --jq .
# or: curl -sS https://api.github.com/versions
```

Use the newest date in that list for github.com. Enterprise Server often lags and may only advertise `2022-11-28`. Use what `/versions` returns on that host, not the github.com latest.

```bash
gh api repos/OWNER/REPO \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10"
```

When a newer dated version appears in `GET /versions`, switch the header to that date. Unsupported dates return `410 Gone` on github.com.

## GraphQL

```bash
gh api graphql -f query='
  query($owner:String!, $name:String!) {
    repository(owner:$owner, name:$name) {
      pullRequests(first: 10, states: OPEN) { nodes { number title url } }
    }
  }
' -f owner=OWNER -f name=REPO
```

## When to use which endpoint family

| Need | Prefer first | `gh api` only if |
|---|---|---|
| List/create PR | `gh pr` | custom fields, requested teams, fine merge state |
| List/create issue | `gh issue` | issue types, field values, sub-issues |
| File contents | clone + `git` / editor | no working tree and a tiny patch |
| Checks on a PR | `gh pr checks` | check-run annotations |
| Projects v2 | (limited `gh project`) | item field mutations |
| Rulesets, environments, custom properties | — | yes |
| Dependabot / code scanning | — | yes |
| Compare two refs | `git diff a...b` | remote-only compare |

Writing file contents through the Contents API (`PUT /repos/.../contents/path`) is possible but inferior to `git commit` + `git push`. It creates awkward commits, fights with branch protection, and does not run local hooks/tests. Use it only when a clone is impossible.

## Pagination

```bash
gh api --paginate repos/OWNER/REPO/issues
gh api --paginate --slurp repos/OWNER/REPO/issues --jq '.[].number'
```

For GraphQL, loop on `pageInfo.hasNextPage` / `endCursor`. Do not guess page counts.

## Useful REST snippets

Authenticated user:

```bash
gh api user --jq '{login,id,name}'
```

Repo permission and default branch:

```bash
gh api repos/OWNER/REPO --jq '{default_branch, visibility, permissions}'
```

Compare refs:

```bash
gh api repos/OWNER/REPO/compare/main...feature/slug --jq '{status,ahead_by,behind_by,total_commits}'
```

PR files (if `gh pr diff` is too large and you only need paths):

```bash
gh api repos/OWNER/REPO/pulls/42/files --paginate --jq '.[].filename'
```

Commit status / check runs:

```bash
gh api repos/OWNER/REPO/commits/SHA/check-runs --jq '.check_runs[] | {name,status,conclusion}'
```

Code search (still prefer `gh search code` when it is enough):

```bash
gh api "search/code?q=repo:OWNER/REPO+filename:go.mod"
```

## Raw curl fallback

Only if `gh` cannot run:

```bash
curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
     -H "Accept: application/vnd.github+json" \
     -H "X-GitHub-Api-Version: 2026-03-10" \
     https://api.github.com/repos/OWNER/REPO
```

Never pass a token on the query string. Never log the header value.

Enterprise Server base URL is `https://HOST/api/v3`. `gh --hostname HOST api ...` still beats hand-built URLs.

## Error bodies

`gh api` prints the GitHub JSON error. Read `message`, `documentation_url`, and `errors[]` before retrying. Repeated 403s against the same endpoint mean permission or SSO, not a bad flag.

Rate limit leftovers:

```bash
gh api rate_limit --jq '.resources.core'
```

Back off on 403/429 with `X-RateLimit-Reset`. Do not tight-loop search endpoints.

## Safety on write APIs

- Send the smallest JSON body that performs the ask.
- Include `sha` when updating a file via Contents API so you do not overwrite a concurrent change.
- Do not call `DELETE /repos/OWNER/REPO` unless the user named that exact repo and said delete.
- Prefer creating a PR over committing to the default branch through the API.
