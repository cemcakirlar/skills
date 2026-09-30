# skills

Agent skills for `npx skills add`. Source of truth for reusable workflows.

Install from this repo:

```bash
npx skills add cemcakirlar/skills --list
npx skills add cemcakirlar/skills --skill github-cli
npx skills add cemcakirlar/skills --all
```

Pin a ref or one skill:

```bash
npx skills add cemcakirlar/skills#main
npx skills add cemcakirlar/skills@github-cli
npx skills use cemcakirlar/skills@github-cli
```

Global install into detected agents:

```bash
npx skills add cemcakirlar/skills --skill github-cli -g -y
```

Also works with GitHub CLI, if you have `gh skill`:

```bash
gh skill install cemcakirlar/skills github-cli
```

## Layout

```
skills/
  <skill-name>/
    SKILL.md
    references/     # optional
    scripts/        # optional
    assets/         # optional
```

Each skill is a folder with a `SKILL.md`. Add new topics as sibling folders under `skills/`. Categories may be one extra directory level (`skills/<topic>/<name>/SKILL.md`).

## Catalog

| Skill | What it is for |
|---|---|
| [github-cli](skills/github-cli/SKILL.md) | GitHub work from the terminal with `git`, `gh`, and `gh api` |

## Authoring

1. `npx skills init skills/my-skill` or copy an existing folder.
2. Keep `name` in the frontmatter identical to the folder name.
3. Put long recipes in `references/`, repeatable checks in `scripts/`.
4. Smoke-test without installing: `npx skills use ./skills@my-skill` from a clone, or `npx skills add . --list` at the repo root.
5. After push, verify discovery: `npx skills add cemcakirlar/skills --list`.

Consumers refresh with `npx skills update`.

## License

MIT. See [LICENSE](LICENSE).
