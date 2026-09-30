# skills

Agent skills used from this repository.

| Skill                                              | What it is for                              |
| -------------------------------------------------- | ------------------------------------------- |
| [github-cli](skills/github-cli/SKILL.md)           | GitHub repos with `git`, `gh`, and `gh api`                                  |
| [github-projects](skills/github-projects/SKILL.md) | GitHub Projects v2 with `gh project`                                         |
| [github-flow](skills/github-flow/SKILL.md)         | End-to-end issue, PR, project board, and deploy automation with `flow.sh`   |

```bash
npx skills add cemcakirlar/skills --list
npx skills add cemcakirlar/skills --skill github-cli
npx skills add cemcakirlar/skills --skill github-projects
npx skills add cemcakirlar/skills --skill github-flow
npx skills add cemcakirlar/skills --all

npx skills update github-cli
npx skills update github-projects
npx skills update github-flow

npx skills remove github-cli
npx skills remove github-projects
npx skills remove github-flow
```

MIT. See [LICENSE](LICENSE).
