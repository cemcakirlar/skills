# skills

Agent skills used from this repository.

| Skill                                              | What it is for                                                                       |
| -------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [github-cli](skills/github-cli/SKILL.md)           | GitHub repos with `git`, `gh`, and `gh api`                                          |
| [github-projects](skills/github-projects/SKILL.md) | GitHub Projects v2 with `gh project`                                                 |
| [github-flow](skills/github-flow/SKILL.md)         | End-to-end issue, PR, project board, and deploy automation with `flow.sh`            |
| [github-release](skills/github-release/SKILL.md)   | Semantic versioning, changelog generation, git tagging, and GitHub releases with `release.sh` |
| [skills-upstream](skills/skills-upstream/SKILL.md) | Inspect drift and batch-sync local skill improvements to upstream with `upstream.sh` |

```bash
npx skills add cemcakirlar/skills --list
npx skills add cemcakirlar/skills --skill github-cli
npx skills add cemcakirlar/skills --skill github-projects
npx skills add cemcakirlar/skills --skill github-flow
npx skills add cemcakirlar/skills --skill github-release
npx skills add cemcakirlar/skills --skill skills-upstream
npx skills add cemcakirlar/skills --all

npx skills update github-cli
npx skills update github-projects
npx skills update github-flow
npx skills update github-release
npx skills update skills-upstream

npx skills remove github-cli
npx skills remove github-projects
npx skills remove github-flow
npx skills remove github-release
npx skills remove skills-upstream
```

MIT. See [LICENSE](LICENSE).
