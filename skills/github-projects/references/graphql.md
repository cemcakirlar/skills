# Projects v2 GraphQL escape hatch

Use this when `gh project` cannot set a field or you only have node IDs. Prefer `gh api graphql` over raw `curl`. These calls spend the GraphQL point bucket, not REST `core`.

## Resolve IDs

```bash
# user or org node id (owner of the project)
gh api user --jq '{login,node_id}'
gh api orgs/ORG --jq '{login,node_id}'

# project + fields
gh project view NUMBER --owner OWNER --format json
gh project field-list NUMBER --owner OWNER --format json
gh project item-list NUMBER --owner OWNER --format json
```

## Add an issue or PR by node ID

First get the issue/PR node ID:

```bash
gh api repos/OWNER/REPO/issues/12 --jq .node_id
```

Then:

```bash
gh api graphql -f query='
  mutation($project:ID!, $content:ID!) {
    addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
      item { id }
    }
  }
' -f project=PVT_... -f content=I_...
```

## Set a single-select field (Status, Priority)

```bash
gh api graphql -f query='
  mutation($project:ID!, $item:ID!, $field:ID!, $option:String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $project
      itemId: $item
      fieldId: $field
      value: { singleSelectOptionId: $option }
    }) {
      projectV2Item { id }
    }
  }
' -f project=PVT_... -f item=PVTI_... -f field=PVTF_... -f option=PVTSO_...
```

Other `value` shapes:

- text: `value: { text: "..." }`
- number: `value: { number: 3 }`
- date: `value: { date: "2026-10-01" }`

## Create a project when `gh project create` is not enough

```bash
gh api graphql -f query='
  mutation($owner:ID!, $title:String!) {
    createProjectV2(input: { ownerId: $owner, title: $title }) {
      projectV2 { id title url number }
    }
  }
' -f owner=U_... -f title='Roadmap'
```

## Cost and quota

A mutation is not 1 REST request. Check points when a burst is coming or a 403 is ambiguous:

```bash
gh api rate_limit --jq '.resources.graphql'
gh api graphql -f query='query { rateLimit { limit remaining used resetAt cost } }'
```

Ask only the fields you will use. One `item-list --format json` plus targeted mutations beats N `view` queries. Do not nest `first: 100` connections unless the user needs that page.

## Guardrails

- Mutations need the `project` scope and permission on that owner.
- Send the smallest mutation that performs the ask.
- Do not delete a project (`deleteProjectV2`) unless the user named it and said delete.
- Board view layout is a poor GraphQL target. Use `--web` if the user needs to see columns.
- On GraphQL `remaining: 0`, stop. Do not fall back to hammering REST equivalents of the same project data.
