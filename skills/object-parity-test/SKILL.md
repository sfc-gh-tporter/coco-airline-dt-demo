---
name: object-parity-test
description: "Prove that a refactored or replacement object returns the SAME results as the incumbent object it replaces, and (for dynamic tables) that it refreshes incrementally. Use when: validating a rewrite/migration, comparing two tables/views/dynamic tables for equivalence, regression-testing a refactor, confirming a dynamic table is genuinely incremental, or before swapping a new object in for an old one. Triggers: parity test, equivalence check, validate the rewrite, validate the refactor, do the results match, compare new vs old object, regression test this change, prove the dynamic table matches the legacy table, confirm incremental refresh. This skill ONLY validates result equivalence and incremental behavior - it does NOT deploy, push, or configure any infrastructure."
---

# Object Parity Test

Generate and run SQL that proves a **candidate** object (the new/refactored one) produces results
equivalent to the **incumbent** object it replaces, then report a structured PASS/FAIL. For dynamic
tables, also prove the refresh is genuinely incremental.

## When to Use
- An object was refactored or replaced (e.g. a full-refresh table replaced by an incremental dynamic
  table, a dbt model rewritten, a view swapped for a table) and you need to prove equivalence before
  trusting/swapping it.
- You want to confirm a dynamic table refreshes incrementally (only changed partitions), not fully.

## When NOT to Use / Not to Be Confused With
- This skill does **not** deploy, push to git, or set up GitHub Actions / CI/CD / service accounts /
  secrets. For provisioning GitHub Actions deployment, that is a different, separate skill
  (`snowflake-cicd-github-actions`) and is unrelated to this validation step.
- Run this against a **dev/clone** object. It writes test rows into base tables, so never point the
  incremental-behavior check at production.

## Workflow

### Step 1: Identify the two objects
**Goal:** know what is being compared.

Ask (or infer from context) the fully-qualified names of:
- **CANDIDATE** - the new object (e.g. `<db>.CURATED.ROUTE_DAILY_PERFORMANCE_DT`)
- **INCUMBENT** - the object it replaces (e.g. `<db>.CURATED.ROUTE_DAILY_PERFORMANCE`)

Confirm both exist and which database they live in (prefer a dev clone for the incremental check).

**Stopping point:** confirm the two objects before generating tests.

### Step 2: Schema comparison
`DESCRIBE` both objects. Compare column names, types, and order. Report any differences. If the
candidate intentionally drops/renames columns, note it and continue with the **comparable** column set.

### Step 3: Detect volatile columns
Equivalence fails on columns whose values are non-deterministic per run - e.g. load/audit timestamps
(`*_ts`, `last_*`, `loaded_at`), `CURRENT_TIMESTAMP()`/`CURRENT_DATE`-derived columns, sequence/surrogate
ids. Identify these and **exclude them from the row-equality test** (or normalize/truncate them), and
say which were excluded and why. This is expected and correct - call it out rather than letting it
cause false failures.

### Step 4: Equivalence checks (over comparable, non-volatile columns)
Generate and run, reporting PASS/FAIL for each (see `references/test-templates.sql` for templates):
1. **Row count** - counts match.
2. **Set equality** - `(candidate EXCEPT incumbent)` AND `(incumbent EXCEPT candidate)` both return 0
   rows. Parenthesize each EXCEPT so set-operator precedence is correct.
3. **Aggregate reconciliation** - SUM/AVG/MIN/MAX of key numeric measures match within a small
   tolerance (floating-point/rounding safe).

### Step 5: Incremental-behavior check (only if CANDIDATE is a dynamic table)
**Goal:** prove the refresh is incremental, not a hidden full recompute.
1. `SHOW DYNAMIC TABLES LIKE '<candidate>'` -> confirm `refresh_mode = INCREMENTAL` (no fallback reason).
2. Insert a **small, localized** batch into the relevant base table **in the dev clone**.
3. `ALTER DYNAMIC TABLE <candidate> REFRESH;`
4. Read `INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY` (join `QUERY_HISTORY` on `query_id` for
   bytes) -> assert `refresh_action = INCREMENTAL` and rows rewritten << total table rows (the change
   stayed localized). Report rows-rewritten vs total and (if available) bytes scanned.

**⚠️ Cost note:** the insert + refresh runs compute. Keep the batch small and the object in a clone.

### Step 6: Report
Present a compact PASS/FAIL table: schema, row count, set-equality (both directions), aggregates,
incremental-behavior. Note any excluded volatile columns. State an overall verdict. Optionally write
the generated SQL to `sql/tests/<object>_parity.sql` for version control.

## Stopping Points
- ✋ Step 1: confirm candidate + incumbent before running.
- ✋ Step 5: before inserting test rows (confirm it is a clone, not prod).
- ✋ Step 6: present results; do not act on them (no swap/drop) without user direction.

## Output
A PASS/FAIL parity report (equivalence + incremental behavior), the generated test SQL, and a clear
verdict on whether the candidate can safely replace the incumbent.
