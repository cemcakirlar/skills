# Projects v2 REST escape hatch

Use these endpoints when `gh project` cannot do the write and you have **owner + project number + integer IDs**. Prefer this over GraphQL for multi-field PATCH and for listing items with field values in one response. GraphQL remains correct when you only have `PVT_` node IDs.

Do not call classic `/projects/{id}` (Projects v1).

Pin the REST version on every call:

```bash
gh api --method GET \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10" \
  /users/OWNER/projectsV2/NUMBER/fields
```

Org-owned boards use `/orgs/ORG/projectsV2/...` instead of `/users/OWNER/projectsV2/...`.

## IDs

| Kind | REST | GraphQL / `gh project --format json` node |
|---|---|---|
| Project | number in the URL (`1`, `12`) | `PVT_…` |
| Item | integer `item_id` | `PVTI_…` |
| Field | integer `id` | `PVTF_…` |
| Single-select / iteration option | integer or option id string in `value` | `PVTSO_…` |

`gh project field-list NUMBER --owner OWNER --format json` and `item-list --format json` often include both. Put the **numeric** `id` in REST paths and PATCH bodies. Putting a `PVT_` string in `/items/{item_id}` fails.

## Token caveats

User-owned `/users/{username}/projectsV2/...` routes frequently **reject** GitHub App tokens and fine-grained PATs. Classic PAT or `gh auth login` OAuth is the usual fit.

Org-owned `/orgs/{org}/projectsV2/...` routes accept fine-grained tokens that have Projects read/write on that org.

A 403 here is often token type or `project` scope, not rate limit. Check `gh auth status` before assuming quota.

## List fields

```bash
gh api --paginate \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10" \
  /users/OWNER/projectsV2/NUMBER/fields
```

## List items with field values

```bash
gh api --paginate \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10" \
  "/users/OWNER/projectsV2/NUMBER/items?fields=123,456"
```

`fields` is a list of integer field IDs. Omit it only when you do not need custom values (response is smaller).

## Add an issue or PR

```bash
gh api --method POST \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10" \
  /users/OWNER/projectsV2/NUMBER/items \
  -f type=Issue -F id=12
```

`type` is `Issue` or `PullRequest`. `id` is the issue/PR **database id** from `gh issue view N --json id`, not `#N` and not `I_…`. Prefer `gh project item-add --url` when you have the HTML URL.

## Update fields on one item

One PATCH can set several fields. This is the main reason to pick REST over a stack of GraphQL mutations.

```bash
gh api --method PATCH \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2026-03-10" \
  /users/OWNER/projectsV2/NUMBER/items/ITEM_ID \
  --input - <<'JSON'
{
  "fields": [
    {"id": 123, "value": "Notes"},
    {"id": 456, "value": 3},
    {"id": 789, "value": "2026-10-01"},
    {"id": 321, "value": "OPTION_OR_ITERATION_ID"}
  ]
}
JSON
```

- text / number / date: raw value
- single-select / iteration: option or iteration id, not the label
- clear a field: `"value": null`

## Delete or skip

Prefer `gh project item-archive` for "take it off the board". REST `DELETE .../items/{item_id}` removes the item from the project; only do that when the user asked to delete the item link.

## Rate limits

These calls count against REST `core`, not GraphQL points.

```bash
gh api rate_limit --jq '.resources.core | {remaining,limit,reset}'
```

If GraphQL `remaining` is exhausted and `core` is healthy, prefer this file over `references/graphql.md` for list + PATCH. If `core` is exhausted, do not fall back to unauthenticated REST (60/hour).

## When to stay on GraphQL

- The only IDs you have are `PVT_` / `PVTI_` / `PVTF_`
- User REST returns 403 with a fine-grained token and you cannot switch token type
- You need a view layout or a mutation this REST family does not expose
