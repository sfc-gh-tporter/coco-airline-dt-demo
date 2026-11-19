---
name: dbt-slice-test
description: "Test a change to the airline dbt dynamic-table DAG (DBT-Actions/dbt/airline) in a zero-copy dev clone: rebuild only the changed models and everything downstream, run their dbt tests, and prove parity against prod (row counts and existing columns unchanged, still INCREMENTAL). Use when: testing a dbt model change in dev, blast radius of a model change, slice build, parity test, before opening a PR for the dbt demo. Triggers: test my dbt change, slice test, blast radius, parity, dev clone, prove nothing downstream breaks."
---

# dbt slice test (airline dbt DT demo)

Proves a dbt change is safe **before** the PR, by rebuilding only the slice of the DAG it touches.
CI (`.github/workflows/dbt-pr.yml`) runs the same steps in `AIRLINE_DBT_PR_<n>`.

## Facts
- Project: `DBT-Actions/dbt/airline` (dbt 1.12.3, dbt Projects on Snowflake). Every model is an
  INCREMENTAL dynamic table.
- Prod: `AIRLINE_DBT_PROD`, project object `AIRLINE_DBT_PROD.DBT.AIRLINE_DBT_PROD_PROJECT`.
- Dev clone: `AIRLINE_DBT_DEV`, created ONLY via `CALL airline_dbt_prod.ops.sp_clone_for_ci('AIRLINE_DBT_DEV')`
  (owner's-rights proc; hands the clone to `AIRLINE_DBT_CI_RL`). Never clone prod by hand.
- Slice = selector `changed_slice` (selectors.yml): models whose SQL/macros changed vs prod's last
  successful run, plus all downstream. State comes from
  `IMPORTS = (SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET('AIRLINE_DBT_PROD.DBT.AIRLINE_DBT_PROD_PROJECT') AS 'state')`.
- The slice must be built with `--full-refresh`: dbt-snowflake 1.12 does not replace an existing
  dynamic table when only its SQL changes.
- Every EXECUTE needs `ENV_VARS = ('DBT_TARGET_DATABASE' = 'AIRLINE_DBT_DEV')` and `--target dev`.
- SQL style: keywords UPPERCASE, object names lowercase. Session role: SYSADMIN, warehouse `airline_dbt_wh`.

## Workflow (stop and show results after each step)

1. **Dev clone** (seconds, no compute; cloned DTs start suspended):
   ```sql
   CALL airline_dbt_prod.ops.sp_clone_for_ci('AIRLINE_DBT_DEV');
   ```
2. **Deploy the working copy** into the clone (repo root, Snowflake CLI):
   ```bash
   snow dbt deploy airline_dbt_dev_project --source DBT-Actions/dbt/airline --database AIRLINE_DBT_DEV \
     --schema DBT --dbt-version 1.12.3 --external-access-integration AIRLINE_DBT_PKG_EAI -c <connection>
   ```
3. **Blast radius** - list the slice; tell the user which models will and will not be rebuilt:
   ```sql
   EXECUTE DBT PROJECT airline_dbt_dev.dbt.airline_dbt_dev_project
     ARGS = 'ls --selector changed_slice --resource-type model --output name --state ./imports/state --target dev'
     ENV_VARS = ('DBT_TARGET_DATABASE' = 'AIRLINE_DBT_DEV')
     IMPORTS = (SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET('airline_dbt_prod.dbt.airline_dbt_prod_project') AS 'state');
   ```
4. **Parity baseline** - BEFORE building (quote the comma list):
   ```sql
   EXECUTE DBT PROJECT airline_dbt_dev.dbt.airline_dbt_dev_project
     ARGS = 'run-operation snapshot_parity_baseline --args "{models: ''<m1>,<m2>,...''}" --target dev'
     ENV_VARS = ('DBT_TARGET_DATABASE' = 'AIRLINE_DBT_DEV');
   ```
5. **Build + test the slice only**:
   ```sql
   EXECUTE DBT PROJECT airline_dbt_dev.dbt.airline_dbt_dev_project
     ARGS = 'build --selector changed_slice --full-refresh --state ./imports/state --target dev'
     ENV_VARS = ('DBT_TARGET_DATABASE' = 'AIRLINE_DBT_DEV')
     IMPORTS = (SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET('airline_dbt_prod.dbt.airline_dbt_prod_project') AS 'state');
   ```
6. **Parity** - same model list as step 4. Present the `PARITY|model|rows_before|rows_after|changed|new_rows|new_columns|mode|status|problems`
   lines as a table:
   ```sql
   EXECUTE DBT PROJECT airline_dbt_dev.dbt.airline_dbt_dev_project
     ARGS = 'run-operation assert_parity --args "{models: ''<m1>,<m2>,...''}" --target dev'
     ENV_VARS = ('DBT_TARGET_DATABASE' = 'AIRLINE_DBT_DEV');
   ```

If a build or parity step fails: the slice models in the clone were already replaced, so fix the
code, then start again from step 1 (re-clone; it takes seconds) to get a clean baseline.

## Rules
- Additive changes only: new columns are fine; existing columns and row counts must not change.
- New columns need a description in the model's `_*.yml` (persist_docs writes it to Snowflake).
- Never write to `AIRLINE_DBT_PROD`; never drop or replace anything outside `AIRLINE_DBT_DEV`.
- The demo branch must start with `dbt/` (the reset script relies on it).
