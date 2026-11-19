-- DBT-Actions/scripts/presenter_walkthrough.sql
-- Live demo runbook: "change a model in the middle of a dynamic table DAG, test only what it
-- affects, ship it through Slim CI and an approval-gated deploy". Run section by section.
-- Presenter aid only; never deployed. Style: SQL keywords UPPERCASE, object names lowercase.
-- =====================================================================================

USE ROLE sysadmin;
USE WAREHOUSE airline_dbt_wh;

-- -------------------------------------------------------------------------------------
-- 0. Pre-flight (expect: 7 dynamic tables, all INCREMENTAL; no dev / PR clones; empty log)
-- -------------------------------------------------------------------------------------
SHOW DYNAMIC TABLES IN DATABASE airline_dbt_prod
  ->> SELECT "schema_name", "name", "target_lag", "refresh_mode", "scheduling_state", "rows" FROM $1 ORDER BY 1, 2;
SHOW DATABASES LIKE 'AIRLINE_DBT_%';                      -- only AIRLINE_DBT_ADMIN, AIRLINE_DBT_PROD
SELECT COUNT(*) AS deploy_log_rows FROM airline_dbt_prod.ops.deploy_log;   -- 0
-- git: on main, `git status` clean, no dbt/* branches (bash DBT-Actions/scripts/reset.sh if not)

-- -------------------------------------------------------------------------------------
-- 1. Tour the pipeline
-- -------------------------------------------------------------------------------------
-- Snowsight: Data > Databases > AIRLINE_DBT_PROD > MARTS > MART_NETWORK_WEEKLY > Graph.
--   raw.flight_status_events (70M) -> stg_flight_status_events -> int_flight_status
--   raw.flights/airports/aircraft  -> int_flight_operations   <- the model we change (middle)
--   raw.bookings (94M) -> int_bookings_by_flight ----------\
--                         int_flight_performance -> mart_route_daily -> mart_network_weekly
-- dbt owns the definitions (DBT-Actions/dbt/airline); Snowflake owns the refreshes (target lag).

-- The ops feed already carries a delay code on every delayed / cancelled event ...
SELECT payload:status::VARCHAR AS status, payload:delay_code::VARCHAR AS delay_code, COUNT(*) AS events
FROM airline_dbt_prod.raw.flight_status_events SAMPLE (1)
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- ... but the business-facing marts only know THAT a flight was late, not WHY.
SELECT * FROM airline_dbt_prod.marts.mart_network_weekly ORDER BY week_start DESC, origin_region LIMIT 10;

-- Every refresh is incremental: only changed rows are processed.
SELECT name, refresh_action, state, refresh_start_time
FROM TABLE(airline_dbt_prod.information_schema.dynamic_table_refresh_history(RESULT_LIMIT => 20))
ORDER BY refresh_start_time DESC;

-- -------------------------------------------------------------------------------------
-- 2. Dev environment: a zero-copy clone of ALL of prod (raw data + the whole DAG)
-- -------------------------------------------------------------------------------------
-- Seconds, no storage, and every cloned dynamic table starts SUSPENDED, so it costs nothing until
-- we build something. The guarded proc refuses any name but AIRLINE_DBT_DEV / AIRLINE_DBT_PR_<n>.
CALL airline_dbt_prod.ops.sp_clone_for_ci('AIRLINE_DBT_DEV');
SHOW DYNAMIC TABLES IN DATABASE airline_dbt_dev
  ->> SELECT "schema_name", "name", "scheduling_state", "rows" FROM $1 ORDER BY 1, 2;

-- In the CoCo terminal, create the demo branch (must start with dbt/):
--   git checkout -b dbt/delay-cause

-- -------------------------------------------------------------------------------------
-- 3. >>> Hand off to CoCo - prompt A (the change) <<<
-- -------------------------------------------------------------------------------------
/*
Our ops team wants to know WHY flights are disrupted, not just that they were late. The ops feed
already sends a delay code on every delayed or cancelled event, and int_flight_status carries the
latest one, but int_flight_operations in DBT-Actions/dbt/airline ignores it. Surface a
human-readable delay cause and a flag for whether it was within the airline's control in
int_flight_operations, carry them through int_flight_performance, and give mart_route_daily and
mart_network_weekly counts and delay minutes for controllable vs uncontrollable disruptions.
Additive only: existing columns and numbers must not change, and every model must stay an
INCREMENTAL dynamic table. Document the new columns and add tests for them.
*/

-- -------------------------------------------------------------------------------------
-- 4. >>> Hand off to CoCo - prompt B (test only what it affects) <<<
-- -------------------------------------------------------------------------------------
/*
Use the dbt-slice-test skill to test this change in AIRLINE_DBT_DEV: show me the blast radius,
rebuild only those models with their tests, and prove parity against prod.
*/
-- Expected shape: blast radius 4 of 7 models (the 70M / 94M-row upstream models are NOT rebuilt),
-- all tests pass, parity PASS on every model with only new columns added.

-- -------------------------------------------------------------------------------------
-- 5. Ship it: commit, push, open the PR -> Slim CI
-- -------------------------------------------------------------------------------------
-- CoCo (or by hand): commit on dbt/delay-cause, push, `gh pr create`.
-- Watch "dbt demo: Slim CI (pull request)": clone prod -> deploy -> blast radius -> baseline ->
-- build + test slice -> parity -> sticky report comment -> drop the clone. About 3 minutes.
-- While it runs, the clone is visible (and disappears at the end):
SHOW DATABASES LIKE 'AIRLINE_DBT_PR_%';

-- -------------------------------------------------------------------------------------
-- 6. Merge -> approve dbt-prod -> deploy only the slice to prod
-- -------------------------------------------------------------------------------------
-- Merge the PR. "dbt demo: Deploy (prod)" waits for your approval (environment dbt-prod), then:
-- deploy project -> blast radius vs prod's last run -> recreate only that slice -> smoke test -> log.
SELECT step, status, models, query_tag, message, started_at
FROM airline_dbt_prod.ops.deploy_log ORDER BY started_at;

-- The new columns are live, the untouched upstream models were never recreated:
SHOW DYNAMIC TABLES IN DATABASE airline_dbt_prod
  ->> SELECT "schema_name", "name", "created_on", "refresh_mode", "scheduling_state" FROM $1 ORDER BY "created_on";
SELECT origin_region, week_start, delayed_flights, cancelled_flights,
       controllable_disruptions, uncontrollable_disruptions, controllable_delay_minutes
FROM airline_dbt_prod.marts.mart_network_weekly ORDER BY week_start DESC, origin_region LIMIT 10;

-- Every CI / deploy statement is traceable by query tag:
SELECT user_name, role_name, query_tag, LEFT(query_text, 80) AS query_text, start_time
FROM TABLE(airline_dbt_prod.information_schema.query_history(RESULT_LIMIT => 200))
WHERE query_tag LIKE 'gh:dbt:%' ORDER BY start_time DESC LIMIT 25;

-- -------------------------------------------------------------------------------------
-- 7. Still incremental in prod: land new data, refresh, look at what was processed
-- -------------------------------------------------------------------------------------
USE ROLE airline_dbt_deploy_rl;
USE DATABASE airline_dbt_prod;
CALL data_gen.sp_generate_airline_data(1.0, 'LIVE');       -- ~400 bookings + ~250 events, next 7 days
ALTER DYNAMIC TABLE airline_dbt_prod.marts.mart_network_weekly REFRESH;   -- refreshes upstream in order
SELECT name, refresh_action, state,
       statistics:numInsertedRows::INT AS inserted, statistics:numDeletedRows::INT AS deleted,
       DATEDIFF('millisecond', refresh_start_time, refresh_end_time) / 1000 AS secs
FROM TABLE(airline_dbt_prod.information_schema.dynamic_table_refresh_history(
       NAME_PREFIX => 'AIRLINE_DBT_PROD.', RESULT_LIMIT => 200))
WHERE data_timestamp = (
  SELECT MAX(data_timestamp)
  FROM TABLE(airline_dbt_prod.information_schema.dynamic_table_refresh_history(
         NAME => 'AIRLINE_DBT_PROD.MARTS.MART_NETWORK_WEEKLY'))
  WHERE refresh_trigger = 'MANUAL')
ORDER BY refresh_start_time;
-- Expect all 7 models INCREMENTAL, a few hundred rows each (dry run: 250 events, 396 booking
-- rollups, 14 of 371 weekly rows), about 3 seconds per model.
USE ROLE sysadmin;

-- -------------------------------------------------------------------------------------
-- 8. Reset (after the demo): GitHub + Snowflake in one command, from the repo root
-- -------------------------------------------------------------------------------------
--   bash DBT-Actions/scripts/reset.sh            # default connection demo156
-- Closes dbt/* PRs, restores DBT-Actions/ from dbt-baseline-v1, drops dev / PR clones, empties
-- the deploy log, and rebuilds only the changed prod slice from the baseline code.
-- A validated reference copy of the change lives on the dbt-solution branch (rehearsal fallback).
