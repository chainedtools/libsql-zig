# GitHub settings for Graphite + Linear

This repo is optimized for **Graphite stacked PRs** and **Linear** issue tracking.
Apply these in the GitHub UI (or org rulesets). Graphite cannot fully automate them
from the repo tree.

Official refs:

- [Graphite GitHub configuration](https://graphite.com/docs/github-configuration-guidelines)
- [Graphite recommended CI](https://graphite.com/docs/setup-recommended-ci-settings)
- [Linear GitHub integration](https://linear.app/docs/github)

## Repository settings

| Setting | Value | Why |
| --- | --- | --- |
| Limit how many branches/tags can be updated in a single push | **Disabled** (or very high) | Graphite pushes stack branches atomically |
| Automatically delete head branches | **Enabled** | After merging downstack, GitHub retargets upstack PRs |

## Branch protection / rulesets (default branch: `master`)

### Required for Graphite

| Rule | Value |
| --- | --- |
| Dismiss stale pull request approvals when new commits are pushed | **Disabled** |
| Require approval of the most recent reviewable push | **Disabled** |
| Require merge queue (GitHub) | **Disabled** (use Graphite MQ if needed) |
| Require deployments to succeed before merging | **Disabled** |

### Recommended

| Rule | Value |
| --- | --- |
| Require a pull request before merging | **Enabled** |
| Require approvals | **1** (or team policy) |
| Require status checks to pass | **Enabled** (mark real CI required) |
| Require conversation resolution | **Enabled** |
| Require linear history | **Enabled** (squash or rebase merge) |
| Include administrators | optional |

## Merge strategies

- Prefer **squash** or **rebase** merge (linear history).
- Merge **stacks from Graphite** (bottom-up or “merge when ready”), not out-of-order GitHub merges.
- Final land PR: `trunk-{KEY}-N` → `master` via squash.

## Linear (org / workspace)

1. Connect GitHub at [Linear → Integrations → GitHub](https://linear.app/settings/integrations/github).
2. Enable this repository for the workspace.
3. Per-team PR automations: draft → started, open → In Progress, merge → Done.
4. GitHub **Autolink**: `https://linear.app/iresolved/issue/KEY-<num> (example: WORGO-123)` with prefix `DB-`.
5. Prefer issue ID in **branch name** and **PR title**; use magic words in body (`Fixes DB-123`).

## Secrets (1Password)

GitHub stores **one** Actions secret per repo. Everything else is loaded at runtime from the
1Password vault **`github actions`** via the service account.

| GitHub secret | Purpose |
| --- | --- |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service account token (only secret on GitHub) |

| 1Password item (vault `github actions`) | Field | Env / consumer | Purpose |
| --- | --- | --- | --- |
| `GRAPHITE_CI_TOKEN` | `credential` | `GRAPHITE_CI_TOKEN` | Graphite CI Optimizations (`op://github actions/GRAPHITE_CI_TOKEN/credential`) |

Create the Graphite token in [Graphite → CI Optimizations](https://app.graphite.com/settings/ci-optimizations), store it in 1Password, then remove any legacy `GRAPHITE_CI_TOKEN` GitHub secret.


## CodeRabbit / Sourcery / Renovate (Graphite)

### CodeRabbit (`.coderabbit.yaml`)

- `reviews.auto_review.base_branches: [".*"]` — review PRs into **any** base (stack parents, `trunk-KEY-N`, default).
- Default branch is always included; `".*"` is what fixes “only reviews main/master”.
- Skips bot authors: renovate, dependabot, graphite-app, linear, sourcery-ai.
- Stacked autofix: `@coderabbitai autofix stacked pr`.

### Sourcery (`.sourcery.yaml`)

- `github.sourcery_branch: sourcery/{base_branch}` — suggestion branches off the **PR head** (Graphite layer).
- Config is read from the **default branch** after merge.
- **Dashboard:** disable “default branch only” if present so mid-stack PRs are reviewed.
- Label `sourcery-ignore` / `dependencies` skips suggestion PRs on Renovate noise.

### Renovate (`renovate.json`)

- `baseBranchPatterns: ["$default"]` only — **never** open dep PRs onto `trunk-*` or stack parents.
- `platformAutomerge` / `automerge`: false — merge via Graphite or squash on default.
- Branch prefix `renovate/` keeps dep work out of human issue trunks.
- Install the Renovate GitHub App on the org; no extra token in-repo.

