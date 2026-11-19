---
name: object-parity-test
description: "Prove that a refactored or replacement object returns the SAME results as the incumbent object it replaces, and (for dynamic tables) that it refreshes incrementally. Runs in a developer sandbox schema of zero-copy clones, never in prod. Use when: validating a rewrite/migration, comparing two tables/views/dynamic tables for equivalence, regression-testing a refactor, confirming a dynamic table is genuinely incremental, or before swapping a new object in for an old one. Triggers: parity test, equivalence check, validate the rewrite, validate the refactor, do the results match, compare new vs old object, regression test this change, prove the dynamic table matches the legacy table, confirm incremental refresh. This skill ONLY validates result equivalence and incremental behavior - it does NOT deploy, push, or configure any infrastructure."
---

# Object Parity Test

Generate and run SQL that proves a **candidate** object (the new/refactored one) produces results
equivalent to the **incumbent** object it replaces, then report a structured PASS/FAIL. For dynamic
tables, also prove the refresh is genuinely incremental.

## Where it runs: the developer sandbox
Our team develops in a personal sandbox schema, `<DEV_DB>.<DEV_SCHEMA>` (for example
`AIRLINE_DEV.<your_user>`), that holds **zero-copy clones** of the prod tables the change reads
and the incumbent it replaces. The candidate is built in that same schema on top of the clones.

- Both objects being compared live in the sandbox. Never run these checks against prod objects.
- The incremental check **writes test rows** into the sandbox clones. That is safe (clones are
  copy-on-write; prod is untouched) and it is the only place this skill ever writes.
- If the sandbox or a clone is missing, stop and tell the user what to create; do not create
  clones of prod yourself unless asked.

## When to Use
- An object was refactored or replaced (e.g. a full-refresh table replaced by an incremental dynamic
  table, a dbt model rewritten, a view swapped for a table) and you need to prove equivalence before
  shipping it.
- You want to confirm a dynamic table refreshes incrementally (only changed groups), not fully.

## When NOT to Use
- This skill does **not** deploy, commit, push, or set up CI/CD. Packaging the change for a pull
  request is the `pipeline-change-shipping` skill.

## Workflow

### Step 1: Identify the two objects
Infer (or ask for) the fully-qualified names, both in the sandbox:
- **CANDIDATE** - the new object, e.g. `<DEV_DB>.<DEV_SCHEMA>.<NEW_OBJECT>`
- **INCUMBENT** - the clone of the object it replaces, e.g. `<DEV_DB>.<DEV_SCHEMA>.<OLD_OBJECT>`

Confirm both exist. Confirm the incumbent clone is in sync with the base clones (it was cloned
at the same time as the inputs); if it is not, say so before comparing.

**Stopping point:** confirm the two objects before generating tests.

### Step 2: Schema comparison
`DESCRIBE` both objects. Compare column names, types, and order. Report differences. If the
candidate intentionally drops/renames columns, note it and continue with the **comparable** set.

### Step 3: Detect volatile columns
Equivalence fails on columns whose values are non-deterministic per run - load/audit timestamps
(`*_ts`, `last_*`, `loaded_at`), `CURRENT_TIMESTAMP()`/`CURRENT_DATE`-derived columns, surrogate
ids. Exclude them from the row-equality test (or normalize them) and say which were excluded and why.

### Step 4: Equivalence checks (comparable, non-volatile columns)
Run and report PASS/FAIL for each (templates in `references/test-templates.sql`):
1. **Row count** - counts match.
2. **Set equality** - `(candidate EXCEPT incumbent)` and `(incumbent EXCEPT candidate)` both return
   0 rows. Parenthesize each EXCEPT so set-operator precedence is correct.
3. **Aggregate reconciliation** - SUM of key numeric measures match within a small tolerance.

### Step 5: Incremental-behavior check (only if CANDIDATE is a dynamic table)
1. `SHOW DYNAMIC TABLES LIKE '<candidate>' IN SCHEMA <DEV_DB>.<DEV_SCHEMA>` -> confirm
   `refresh_mode = INCREMENTAL` and no `refresh_mode_reason`.
2. Insert a **small, localized** batch into the sandbox clone(s) of the base table(s) - shaped like
   a real feed (a few hundred rows on near-term dates), see the template.
3. `ALTER DYNAMIC TABLE <candidate> REFRESH;` and keep its `statistics` output.
4. Read `INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY` for the candidate -> assert the latest
   manual refresh has `refresh_action = INCREMENTAL` and rows rewritten << total rows.
   Report rows rewritten vs total. Report elapsed time honestly; do not claim a speedup you did
   not measure.

**Cost note:** keep the batch small; it runs on the session warehouse.

### Step 6: Report
A compact PASS/FAIL table: schema, row count, set equality (both directions), aggregates,
refresh mode, incremental behavior (rows rewritten / total). Note excluded volatile columns and
any sandbox caveats (e.g. the incumbent no longer matches after the test batch, which is expected).
State an overall verdict and a one-line summary the user can paste into a commit message.

## Stopping Points
- Step 1: confirm candidate + incumbent before running.
- Step 5: before inserting test rows, state the exact sandbox tables being written to.
- Step 6: present results; do not swap, drop, deploy, or commit anything.

## Output
A PASS/FAIL parity report (equivalence + incremental behavior), the SQL that was run, and a clear
verdict on whether the candidate can safely replace the incumbent.
