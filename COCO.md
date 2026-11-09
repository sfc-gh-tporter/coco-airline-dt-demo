# Project Conventions (CoCo)

Conventions for Cortex Code when working in this repo. (Project context, not a deployed object.)

## What this repo is
An airline data pipeline in Snowflake (`AIRLINE_PROD`) with a production-grade CI/CD workflow
on GitHub Actions. Changes are proposed as pull requests; automated checks in Snowflake decide
whether they are safe; an approved merge deploys to production.

## How a change ships (follow this every time)
1. **Branch.** Create a feature branch. Never commit or push to `main` - it is protected and
   only accepts merged pull requests.
2. **Write the change** as SQL under `sql/` (one file per object, fully qualified
   `AIRLINE_PROD.<SCHEMA>.<OBJECT>` names, `USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;` at the top).
   CI rewrites these names to the pull request's own test schemas, so write them for prod.
3. **Add tests** when replacing or refactoring an object: a parity test under `tests/parity/`
   (use the `object-parity-test` skill; see its "CI parity test" section for the file contract).
4. **Open a pull request** with `gh pr create`. The `ci` check builds a test environment in
   `AIRLINE_CI` containing zero-copy clones of only what the PR touches, deploys the change
   there, runs the quality gates, and posts a results comment on the PR.
5. **If the `ci` check fails**, read why - the PR comment, or `gh run view <run-id> --log-failed`
   - fix the cause on the same branch, and push. CI re-runs automatically.
6. **Merge** when `ci` is green. The merge triggers `deploy.yml`, which waits for a reviewer to
   approve the `prod` environment, then deploys, smoke-tests, and rolls back automatically on failure.

## Quality gates (enforced by CI, not by convention)
| Gate | What it checks |
|---|---|
| Deploy into PR environment | the changed SQL (plus anything downstream of it) applies cleanly |
| Dynamic table refresh mode | changed dynamic tables are `INCREMENTAL` with no fallback |
| Incremental behavior | a localized batch refreshes `INCREMENTAL` and rewrites only a small slice |
| Parity vs incumbent | `tests/parity/*.sql` checks all pass |
| SQL lint | sqlfluff findings (advisory) |

CI may enforce additional standards; the PR comment always says which check failed and why.
Use the matching skill to fix it (e.g. `change-documentation` for documentation findings).

## Commit message format (data changes)
```
<type>(<scope>): <concise summary>

What:       <object> (<type/key props>) replaces <incumbent, if any>
Why:        <rationale>
Validated:  <how it was validated>
Docs:       <table + N/N columns documented>

Generated with Cortex Code
```

## Auth and environments (already configured - do not change)
- GitHub OIDC -> Snowflake workload identity federation. No key, password, or token is stored
  in GitHub; `SNOWFLAKE_ACCOUNT` is the only secret.
- `SVC_GH_ACTIONS_CI` (role `AIRLINE_CI_RL`, read-only on prod) runs PR checks.
- `SVC_GH_ACTIONS_AIRLINE` (role `PROD_GH_ACTIONS_DEPLOY_RL`) deploys, and can only be used by a
  job that passed the `prod` environment approval.
- `sql/00_account/**` is one-time ACCOUNTADMIN bootstrap and is never deployed by CI.

## IMPORTANT: CI/CD setup is out of scope for normal work here
GitHub Actions is **already configured** (`.github/workflows/pr.yml`, `pr_cleanup.yml`,
`deploy.yml`, engine in `scripts/ci/ci.py`). Do **NOT** invoke the `snowflake-cicd-github-actions`
skill during development, validation, documentation, or the demo flow - that skill is for
one-time CI/CD *setup* only.

## Reset
After a demo: `snow sql -f scripts/reset.sql -c <connection>` then `bash scripts/reset_git.sh`.
