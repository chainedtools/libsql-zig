# PMS multi-repo: Linear + Graphite workflow

This directory holds **separate GitHub repos** under `solvedggorg/*`. Each repo
is optimized for the same delivery model:

1. **Linear** is the system of record for product issues.
2. **Graphite** is the stacking CLI for small, reviewable PRs.
3. **Issue trunks** isolate each Linear issue before landing on the default branch.

## Team → repo map

| Repo | Linear team | Key | Default branch |
| --- | --- | --- | --- |
| clerk-zig | AUTH | AUTH | master |
| deploy | Deploy | DEPLOY | master |
| docs | DOCS | DOCS | main |
| hasky | Hasky | HASKY | master |
| pyppi | Pyppi | PYPPI | master |
| rusty | Rusty | RUSTY | master |
| scripty | Scripty | SCRIPTY | master |
| trunker | Trunker | TRUNKER | master |
| umcp | UMCP | UMCP | master |
| worgo | Worgo | WORGO | master |
| yappy | Yappy | YAPPY | master |
| zig-libsql | db | DB | master |

## Delivery shape (every repo)

```text
default branch ──────────────────────────────►
   \
    trunk-KEY-N          # one Linear issue
       ├── PR 1 (stack)
       ├── PR 2
       └── PR 3
              └── land PR → default (squash)
```

## Per-repo files

| Path | Role |
| --- | --- |
| `CONTRIBUTING.md` | Human + agent recipe |
| `AGENTS.md` | Agent rules including Linear MCP |
| `.github/pull_request_template.md` | Linear + stack checklist |
| `.github/GITHUB_SETTINGS.md` | Branch protection + secrets checklist |
| `.github/workflows/graphite-ci-optimizer.yml` | Optional CI skip for mid-stack (repos with heavy CI) |

## Org setup checklist (once)

### Linear

- [ ] GitHub app installed for `solvedggorg` with all PMS repos
- [ ] Team ↔ repo mapping in Linear GitHub settings
- [ ] PR/commit automations per team (draft / open / review / merge)
- [ ] Autolink references on each GitHub repo (`KEY-` → Linear issue URL)
- [ ] Agents: `LINEAR_API_KEY` exported for MCP

### Graphite

- [ ] Graphite GitHub app on the org
- [ ] CI Optimizations enabled per heavy-CI repo + `GRAPHITE_CI_TOKEN` secret
- [ ] Repo settings: no atomic multi-branch push limit; auto-delete head branches
- [ ] Branch protection: **do not** dismiss stale approvals; **do not** require latest push approval
- [ ] Prefer Graphite merge (or MQ), not GitHub merge queue for stacks
- [ ] CI: PR types `opened/reopened/synchronize` only; ignore `graphite-base/*` noise

### Review culture

- Review each stack PR as an independent change; start bottom-up
- Submit layers when ready; mark WIP as draft
- Prefer stacks over PRs ≫ 250 LOC / 25 files when practical

## Research basis

Synthesized from Graphite docs (GitHub config, stacking + CI, review practices)
and Linear docs (GitHub linking, magic words, PR automations) via Exa + Firecrawl
(2026-07-25).

## CodeRabbit, Sourcery, Renovate

| Tool | Config file | Graphite rule |
| --- | --- | --- |
| CodeRabbit | `.coderabbit.yaml` | `base_branches: [".*"]` so mid-stack + `trunk-KEY-N` PRs are reviewed |
| Sourcery | `.sourcery.yaml` | `sourcery/{base_branch}` suggestion branches; dashboard must not restrict to default only |
| Renovate | `renovate.json` | `baseBranchPatterns: ["$default"]` only — dep PRs never target issue trunks |

Human stacks review on every layer; dependency bots only land on `master`/`main`.

