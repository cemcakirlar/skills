# AGENTS

This repository is a multi-skill collection for the `skills` CLI (`npx skills add cemcakirlar/skills`).

## Rules

- Put every skill under `skills/<name>/` with a `SKILL.md`.
- `name` in YAML frontmatter must match the folder name (kebab-case).
- Do not put a root `SKILL.md`; that shadows nested skills unless consumers pass `--full-depth`.
- Keep `SKILL.md` short. Long command catalogs go in `references/`.
- Scripts must be safe to run: no tokens in output, no force-push to default branches.
- After adding a skill, list it in the README catalog table.
- Do not commit secrets, `.env`, or machine-local agent directories (`.claude/`, `.agents/`).
