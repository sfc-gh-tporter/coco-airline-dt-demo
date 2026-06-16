# Project Conventions (CoCo)

Conventions for Cortex Code when working in this repo. (Project context, not a deployed object.)

## What this repo is
A reusable demo showing Cortex Code modernizing a Snowflake pipeline: an inefficient full-refresh
task that rebuilds a route x day KPI mart is converted to an INCREMENTAL dynamic table, validated,
documented, and shipped. The focus is **CoCo in the development workflow**, not data engineering.

## Development standards for a pipeline change
When changing a curated object (e.g. introducing the dynamic table), follow this order:
1. Build/validate on a **clone** (`AIRLINE_PROD_DEV_CL`), never directly in prod.
2. **Validate equivalence** with the `object-parity-test` skill: the new object must match the
   incumbent it replaces (schema, row counts, set equality, aggregates) and, for a dynamic table,
   prove `refresh_action = INCREMENTAL` with a localized rewrite.
3. **Document** with the `change-documentation` skill: table + every column must carry a meaningful
   comment (aids discoverability and future semantic views), and produce a standardized commit message.
4. Commit and push to `main` with a normal git commit (Actions is already configured and fires on push).

## Commit message format (data changes)
```
<type>(<scope>): <concise summary>

What:       <object> (<type/key props>) replaces <incumbent, if any>
Why:        <rationale>
Validated:  <parity PASS/FAIL; incremental confirmed if applicable>
Docs:       <table + N/N columns documented>

Generated with Cortex Code
```

## IMPORTANT: CI/CD setup is out of scope for normal work here
GitHub Actions is **already configured** for this repo (key-pair auth, service user, secrets,
`.github/workflows/deploy.yml`). Do **NOT** invoke the `snowflake-cicd-github-actions` skill during
development, validation, documentation, or the demo flow - that skill is for one-time CI/CD *setup*
only. Day-to-day, deploying means a plain `git push` to `main`; the existing workflow runs itself.

## Reset
After a demo, restore baseline with `scripts/reset.sql` and `git reset --hard baseline-v1`.
