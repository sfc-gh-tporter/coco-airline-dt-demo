-- scripts/presenter_walkthrough.sql
-- Step-2 live demo script. Run section by section with the customer. This file is
-- a presenter aid; it is NOT deployed by GitHub Actions.
-- Style: SQL keywords UPPERCASE, object names lowercase.
-- =====================================================================================

USE ROLE sysadmin;
USE WAREHOUSE airline_demo_wh;

-- -------------------------------------------------------------------------------------
-- 1. Tour the existing (inefficient) pipeline
-- -------------------------------------------------------------------------------------
-- The data: two large structured facts (~6GB bookings, ~5GB events) + a flights dim (~10GB total).
SHOW TABLES IN SCHEMA airline_prod.staging;

SELECT *
FROM airline_prod.staging.bookings LIMIT 100;

SELECT *
FROM airline_prod.staging.flight_status_events LIMIT 100;



-- The whole legacy pipeline is a single scheduled task that FULLY rebuilds the mart.
SELECT GET_DDL('TASK', 'airline_prod.curated.refresh_route_daily_performance_task');

-- The KPI consumers actually use:
SELECT * FROM airline_prod.curated.route_daily_performance ORDER BY revenue_usd DESC LIMIT 10;

-- -------------------------------------------------------------------------------------
-- 2. Show the cost of the anti-pattern: a FULL recompute over ALL history every run
-- -------------------------------------------------------------------------------------
-- Drop a tiny batch of brand-new bookings/events into staging...
CALL airline_prod.data_gen.sp_generate_airline_data(1.0, 'LIVE');

-- ...then run the legacy task and watch it rescan ALL history (~11GB, ~10s) just to reflect
-- a few hundred new rows.
--ALTER TASK airline_prod.curated.refresh_route_daily_performance_task RESUME;
EXECUTE TASK airline_prod.curated.refresh_route_daily_performance_task;  -- run it now

-- Inspect what the full recompute actually scanned (note bytes/time vs rows changed):
SELECT query_id, ROUND(total_elapsed_time/1000,1) AS secs,
       ROUND(bytes_scanned/POW(1024,3),2) AS gb_scanned, rows_produced
FROM TABLE(airline_prod.information_schema.query_history(RESULT_LIMIT=>50))
WHERE query_text ILIKE 'insert overwrite into airline_prod.curated%'
ORDER BY start_time DESC LIMIT 3;

-- Suspend it again before the clone step.
ALTER TASK airline_prod.curated.refresh_route_daily_performance_task SUSPEND;

-- -------------------------------------------------------------------------------------
-- 3. Clone production to a safe dev sandbox (zero-copy, instant) -- run as SYSADMIN
-- -------------------------------------------------------------------------------------
USE ROLE sysadmin;
CREATE OR REPLACE DATABASE airline_prod_dev_cl CLONE airline_prod;

-- -------------------------------------------------------------------------------------
-- 4. >>> Hand off to CoCo (paste this prompt as-is) <<<
-- -------------------------------------------------------------------------------------
/*
Use the /dynamic-tables skill to modernize the curated layer in the airline_prod_dev_cl
database. The staging schema feeds a curated route x day KPI table
(airline_prod_dev_cl.curated.route_daily_performance) today via a scheduled task that
 fully rebuilds the whole table on every run. Replace that full-refresh task with a
 single INCREMENTAL dynamic table in airline_prod_dev_cl.curated that produces the same
KPI columns. Confirm it refreshes incrementally, then show me the DDL before creating
anything.
*/
-- -------------------------------------------------------------------------------------

-- -------------------------------------------------------------------------------------
-- 5. Validate the dynamic table with the object-parity-test skill
-- -------------------------------------------------------------------------------------
/*
Use the /object-parity-test skill to validate the new
airline_prod_dev_cl.curated.route_daily_performance_dt against the incumbent
airline_prod_dev_cl.curated.route_daily_performance it replaces: prove they return the same
results and that the dynamic table refreshes incrementally.
*/
-- CoCo will compare schemas, row counts, EXCEPT both directions, reconcile aggregates, and
-- (in the clone) insert a small batch + refresh to confirm refresh_action = INCREMENTAL with
-- a localized rewrite. Expect PASS on all checks.
-- (Manual fallback queries live in skills/object-parity-test/references/test-templates.sql.)


-- -------------------------------------------------------------------------------------
-- 6. Document the change with the change-documentation skill, then commit + push
-- -------------------------------------------------------------------------------------
/*
Use the /change-documentation skill to add table + column comments to
airline_prod_dev_cl.curated.route_daily_performance_dt for discoverability, and draft a
commit message summarizing the change and the parity-test results.
*/
-- Then have CoCo commit the new dynamic table to main and push. GitHub Actions is already
-- configured and runs automatically on the push - this is a plain `git push`, NOT a CI/CD
-- setup step (the snowflake-cicd-github-actions skill is not used anywhere in this demo).


-- -------------------------------------------------------------------------------------
-- 7. RESET (after the demo) - returns everything to baseline. Bulk data is preserved.
-- -------------------------------------------------------------------------------------
--   Snowflake side - run scripts/reset.sql (drops the clone + dynamic table, recreates
--   the legacy target + full-refresh task SUSPENDED, repopulates the mart):
--       snow sql -f scripts/reset.sql -c demo156
--       (or paste scripts/reset.sql into a worksheet / ask CoCo to run it)
--
--   Git side - return main to "before" (never touch the `solution` branch):
--       git reset --hard baseline-v1
--       git push --force-with-lease origin main
-- -------------------------------------------------------------------------------------
