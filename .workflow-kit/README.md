# PMS workflow kit (Linear + Graphite)

Copy this directory and `WORKFLOW.md` into every product repo. Apply
repo-specific Linear team keys via `CONTRIBUTING.md` / `AGENTS.md`.

## Contents

| Path | Role |
| --- | --- |
| `WORKFLOW.md` | Multi-repo delivery model (also at repo root) |
| `templates/coderabbit.yaml` | CodeRabbit — `base_branches: [".*"]` for stacks |
| `templates/sourcery.yaml` | Sourcery — stack-safe `sourcery/{base_branch}` |
| `templates/renovate.json` | Renovate — `$default` only |
| `workflows/graphite-ci-optimizer.yml` | Graphite CI skip helper |

## Apply

1. Copy `WORKFLOW.md` to repo root.
2. Copy this `.workflow-kit/` directory into the repo.
3. Install templates as `.coderabbit.yaml`, `.sourcery.yaml`, `renovate.json`.
4. Ensure `.github/GITHUB_SETTINGS.md`, PR template, and CONTRIBUTING match the kit.
5. Heavy CI repos: add `graphite-ci-optimizer.yml` and gate expensive jobs.

See root `WORKFLOW.md` for team → key map and org checklist.
