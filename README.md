# skills

Agent skills for `npx skills add`. Source of truth for reusable workflows.

## Install

The CLI reads this GitHub repo, finds every `skills/*/SKILL.md`, then copies or links the ones you choose into your coding agents (Claude Code, Cursor, Codex, Copilot, and others).

```bash
# Show what this repo contains. Does not install anything.
npx skills add cemcakirlar/skills --list

# Install only the github-cli skill into the current project.
npx skills add cemcakirlar/skills --skill github-cli

# Install every skill in the repo into every detected agent. Skips prompts.
npx skills add cemcakirlar/skills --all
```

`--skill` can be repeated. `--all` is `--skill '*' --agent '*' -y`.

### Select a git ref or a single skill

The source string is `owner/repo`, optionally followed by `#ref` and/or `@skill`.

| Suffix | Meaning |
|---|---|
| `#main`, `#v1.2.0`, `#abc1234` | Git branch, tag, or commit. Default is the repo default branch. |
| `@github-cli` | Only that skill, instead of prompting or taking the whole set. |
| `#main@github-cli` | Both: that skill, from that ref. |

```bash
# Install from the main branch (same as omitting #main today).
npx skills add cemcakirlar/skills#main

# Install only github-cli. Same idea as --skill github-cli.
npx skills add cemcakirlar/skills@github-cli

# Same skill, pinned to a tag once you publish one.
npx skills add cemcakirlar/skills#v1.0.0@github-cli
```

`add` writes files onto disk. `use` does not:

```bash
# Build the skill prompt and print it. Nothing is installed.
npx skills use cemcakirlar/skills@github-cli

# Pipe that prompt into an agent, still without a permanent install.
npx skills use cemcakirlar/skills@github-cli | claude
```

Use `use` to try a skill once. Use `add` when you want it available in later sessions.

### Scope and agents

```bash
# User-wide install of one skill, no confirmation prompt.
npx skills add cemcakirlar/skills --skill github-cli -g -y

# Project install into specific agents only.
npx skills add cemcakirlar/skills --skill github-cli -a claude-code -a cursor
```

`-g` / `--global` goes to your home agent dirs. Omit it and the skill stays in the current project.

After the source repo changes, already-installed copies refresh with `npx skills update`.

### GitHub CLI alternative

If you use `gh skill` instead of `npx skills`:

```bash
gh skill install cemcakirlar/skills github-cli
gh skill install cemcakirlar/skills github-projects
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
| [github-projects](skills/github-projects/SKILL.md) | GitHub Projects v2 boards, fields, and items via `gh project` |

## Authoring

1. `npx skills init skills/my-skill` or copy an existing folder.
2. Keep `name` in the frontmatter identical to the folder name.
3. Put long recipes in `references/`, repeatable checks in `scripts/`.
4. Smoke-test without installing: `npx skills use ./skills@my-skill` from a clone, or `npx skills add . --list` at the repo root.
5. After push, verify discovery: `npx skills add cemcakirlar/skills --list`.

## License

MIT. See [LICENSE](LICENSE).
