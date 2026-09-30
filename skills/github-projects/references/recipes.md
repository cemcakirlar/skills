# gh project recipes

Assume `gh auth` includes the `project` scope. Replace `OWNER`, `NUMBER`, and URLs.

## Auth and list

```bash
gh auth status
gh auth refresh -s project

gh project list --owner "@me"
gh project list --owner ORG --limit 50
gh project view NUMBER --owner OWNER
gh project view NUMBER --owner OWNER --format json
gh project view NUMBER --owner OWNER --web
```

`--format json` is the source of node IDs (`id`, field ids, option ids).

## Create, edit, close, copy

```bash
gh project create --owner OWNER --title "Roadmap"
gh project edit NUMBER --owner OWNER --title "New title"
gh project close NUMBER --owner OWNER
gh project copy NUMBER --owner OWNER --dest-owner OTHER --title "Copy"
```

`delete` and `mark-template` are destructive or org-policy adjacent. Only run them when the user named the project and the action.

## Link a repo

```bash
gh project link NUMBER --owner OWNER --repo OWNER/REPO
gh project unlink NUMBER --owner OWNER --repo OWNER/REPO
```

Linking does not add issues. It only associates the project with the repo UI.

## Fields

```bash
gh project field-list NUMBER --owner OWNER
gh project field-list NUMBER --owner OWNER --format json

gh project field-create NUMBER --owner OWNER \
  --name "Priority" --data-type SINGLE_SELECT \
  --single-select-options "Critical,High,Medium,Low"

gh project field-create NUMBER --owner OWNER --name "Due" --data-type DATE
gh project field-create NUMBER --owner OWNER --name "Points" --data-type NUMBER
gh project field-create NUMBER --owner OWNER --name "Notes" --data-type TEXT
```

`--data-type` is `TEXT`, `SINGLE_SELECT`, `DATE`, or `NUMBER`. Iteration fields may need GraphQL or a newer `gh` — if `field-create` rejects `ITERATION`, use `references/graphql.md`.

Do not delete a field unless asked. Status is often a built-in single-select; inspect it before creating a duplicate.

## Items

```bash
gh project item-list NUMBER --owner OWNER --limit 50
gh project item-list NUMBER --owner OWNER --field Status --field Priority
gh project item-list NUMBER --owner OWNER --query "assignee:@me is:open"
gh project item-list NUMBER --owner OWNER --query "label:bug -status:Done"
gh project item-list NUMBER --owner OWNER --format json

gh project item-add NUMBER --owner OWNER --url https://github.com/OWNER/REPO/issues/12
gh project item-add NUMBER --owner OWNER --url https://github.com/OWNER/REPO/pull/34

gh project item-create NUMBER --owner OWNER --title "Draft task" --body "Notes"
gh project item-archive NUMBER --owner OWNER --id PVTI_...
gh project item-delete NUMBER --owner OWNER --id PVTI_...
```

`--query` syntax matches project filter language (`assignee:`, `is:issue`, `label:`, `-status:`). Host support is github.com and recent GHES.

`item-edit` needs IDs. Typical shape (check `gh project item-edit -h` on the installed `gh`):

```bash
gh project item-edit \
  --project-id PVT_... \
  --id PVTI_... \
  --field-id PVTF_... \
  --single-select-option-id PVTSO_...
```

Text / number / date variants use `--text`, `--number`, `--date` instead of `--single-select-option-id`. If the flags differ on this `gh` version, read `-h` and do not guess.

## After opening an issue in github-cli

```bash
ISSUE_URL=$(gh issue view N --repo OWNER/REPO --json url --jq .url)
gh project item-add NUMBER --owner OWNER --url "$ISSUE_URL"
```

Same pattern with `gh pr view`.
