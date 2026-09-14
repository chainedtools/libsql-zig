# Contributing to zig-libsql

Thanks for contributing.

## Linear + Graphite workflow (required for product work)

Internal product work is tracked in **[Linear](https://linear.app)** team **db**
(identifier **`DB`**), not free-form GitHub Issues.

| Piece | Convention |
| --- | --- |
| Linear issue | `DB-N` |
| Issue trunk | `trunk-DB-N` (from `master`) |
| Stack PRs | Graphite stack based on the issue trunk |
| Land PR | `trunk-DB-N` → `master` (squash preferred) |

```text
master ──────────────────────────────────────────►
   \
    trunk-DB-12
       ├── stack PR 1
       ├── stack PR 2
       └── stack PR 3
              └──► land PR: trunk-DB-12 → master
```

**One Linear issue per issue trunk.** Do not mix issues on one `trunk-DB-*` branch.

### Linking (Linear GitHub integration)

1. **Branch name** — include `DB-N` (or copy git branch name from Linear).
2. **PR title** — include `DB-N`.
3. **PR body** — closing: `Fixes DB-N` / `Closes DB-N`; non-closing: `Related to DB-N`.
4. Magic words in **descriptions** need the keyword; title/branch ID alone still links.

### Graphite recipe

```bash
# Install: https://graphite.com/docs/install-the-cli
# Auth:    https://app.graphite.com/settings/cli

git fetch origin
git checkout master && git pull --ff-only

# Issue trunk (refuse if name already exists)
if git show-ref --verify --quiet refs/heads/trunk-DB-N; then
  echo "trunk exists — gt checkout or delete only after land PR merged" >&2
  exit 1
fi
git checkout -b trunk-DB-N origin/master
gt config   # multitrunk: add trunk-DB-N alongside master

gt create --all -m "DB-N: first slice"
gt submit --stack
# …more slices…
gt modify --all && gt submit --stack && gt sync

# Land after stack is green/reviewed
gh pr create --base master --head trunk-DB-N \
  --title "DB-N: <short title>" \
  --body "Closes DB-N."
```

Amend mid-stack with `gt modify`, restack with `gt sync`, push with `gt submit`
(or `--force-with-lease`) — not raw `git push --force`.

Merge stacks from Graphite (or bottom-up into the issue trunk), then land
`trunk-DB-N` → `master`.

See also: [Graphite cheatsheet](https://graphite.com/docs/cheatsheet),
[reviewing stacks](https://graphite.com/docs/best-practices-for-reviewing-stacks),
`.github/GITHUB_SETTINGS.md`.

## Continuous integration + Graphite

Expensive workflows may be gated by **[Graphite CI Optimizations](https://graphite.com/docs/stacking-and-ci)**
(`.github/workflows/graphite-ci-optimizer.yml` + `withgraphite/graphite-ci-action`).

- Mid/upstack PRs can skip when Graphite says so.
- Missing token / API errors **fail open** (CI still runs).
- Secret: `GRAPHITE_CI_TOKEN`.
- Configure stack layers: [Graphite CI Optimizations](https://app.graphite.com/settings/ci-optimizations).

CI triggers use `pull_request` types `opened | reopened | synchronize` only
(not `edited`, which fires when Graphite retargets bases). Temporary
`graphite-base/*` bases should not drive required checks — see
`.github/GITHUB_SETTINGS.md`.

## Agents

See [AGENTS.md](AGENTS.md) for agent-specific rules (Linear MCP, product boundaries).
