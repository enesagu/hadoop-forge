# Contributing

## Before opening a PR

```bash
bash tests/validate-configs.sh    # no cluster needed, seconds
make lint                         # shellcheck, hadolint, XML
make up && make smoke             # the check that actually proves something
```

CI runs all of these plus a real cluster smoke test on both topologies.

## What this repository is for

Teaching Hadoop's internals through working artefacts. Two consequences:

- **Explain the why, inline.** A property without a comment saying why that value
  was chosen is incomplete. The configuration files are documentation that
  happens to execute.
- **Learning-mode shortcuts must be marked.** `dfs.permissions.enabled=false` is
  fine in `conf/pseudo`, labelled as such, and must never appear in
  `conf/cluster` or `conf/ha`. `tests/validate-configs.sh` enforces this.

## Shell scripts

- `set -euo pipefail`, via `scripts/lib/common.sh`.
- Idempotent. Re-running prints `[ skip ]` for work already done.
- Guards, not comments: a step that must not run as root calls `refuse_root`.
- Destructive actions need an explicit opt-in (`FORGE_FORCE_FORMAT=1`,
  `--purge-data`) *and* an interactive confirmation.
- Prefer POSIX tooling over interpreters. These scripts run on freshly
  provisioned hosts where python may not exist.

## Commits

Conventional Commits: `feat(scope):`, `fix(scope):`, `docs:`, `chore:`, `ci:`.

Write the body for someone reading `git log` in a year. Say what changed and why
that was the right call — not what the diff already shows.

## Adding a configuration property

1. Add it with an inline comment explaining the value.
2. Add a row to `docs/04-configuration-reference.md`.
3. If it interacts with memory or replication, extend
   `tests/validate-configs.sh`.

## Reporting bugs

Include the topology (`single` / `cluster` / bare metal), Hadoop and Docker
versions, and the output of `./scripts/health-check.sh`. For a job failure,
`yarn logs -applicationId <id>`.
