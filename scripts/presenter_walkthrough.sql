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
Use the /dynamic-tables skill to modernize the pipeline in the airline_prod_dev_cl
database. The staging schema feeds a curated route x day KPI table
(airline_prod_dev_cl.curated.route_daily_performance) today via a scheduled task that
 fully rebuilds the whole table on every run. Replace that full-refresh task with a
 single INCREMENTAL dynamic table in airline_prod_dev_cl.curated that produces the same
KPI columns. Confirm it refreshes incrementally, then show me the DDL before creating
anything.
*/
-- -------------------------------------------------------------------------------------

-- -------------------------------------------------------------------------------------
-- 5. Validate CoCo's dynamic table in the clone
-- -------------------------------------------------------------------------------------
-- Discover what CoCo created and confirm refresh_mode = INCREMENTAL (not FULL):
SHOW DYNAMIC TABLES IN SCHEMA airline_prod_dev_cl.curated;


--TEST QUERIES
--1. Row counts — should match exactly:
SELECT
  (SELECT COUNT(*) FROM airline_prod_dev_cl.curated.route_daily_performance)     AS legacy_rows,
  (SELECT COUNT(*) FROM airline_prod_dev_cl.curated.route_daily_performance_dt)  AS dt_rows;

--2. Any differing rows in either direction (empty result = the tables are identical).
--   Each EXCEPT is parenthesized so set-operator precedence is correct.
(
  SELECT 'in_legacy_only' AS side, route, flight_date, seats_sold, revenue_usd,
         seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM airline_prod_dev_cl.curated.route_daily_performance
  EXCEPT
  SELECT 'in_legacy_only' AS side, route, flight_date, seats_sold, revenue_usd,
         seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM airline_prod_dev_cl.curated.route_daily_performance_dt
)
UNION ALL
(
  SELECT 'in_dt_only' AS side, route, flight_date, seats_sold, revenue_usd,
         seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM airline_prod_dev_cl.curated.route_daily_performance_dt
  EXCEPT
  SELECT 'in_dt_only' AS side, route, flight_date, seats_sold, revenue_usd,
         seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM airline_prod_dev_cl.curated.route_daily_performance
);

-- Prove incremental: drop a small batch into staging, then refresh the dynamic table.
INSERT INTO airline_prod_dev_cl.staging.bookings
  (booking_id, passenger_id, passenger_name, flight_id, flight_date, fare_usd, seat_class, channel, booking_ts)
SELECT airline_prod_dev_cl.data_gen.booking_seq.NEXTVAL, 1, 'Demo Passenger', f.flight_id,
       f.scheduled_dep_ts::DATE, 250, 'ECONOMY', 'WEB', f.scheduled_dep_ts
FROM airline_prod_dev_cl.staging.flights f LIMIT 200;

-- Substitute the dynamic table name CoCo chose:
ALTER DYNAMIC TABLE airline_prod_dev_cl.curated.ROUTE_DAILY_PERFORMANCE_DT REFRESH;
-- The refresh statistics should show insertedRows ~= deletedRows with a large copiedRows
-- (only the affected route x day groups recomputed) -> incremental, not a full rebuild.

--Test Count val
SELECT COUNT (*), 'route_daily_performance_dt' as table_name
 FROM airline_prod_dev_cl.curated.route_daily_performance_dt
UNION
 SELECT COUNT (*), 'route_daily_performance'
 FROM airline_prod_dev_cl.curated.route_daily_performance;
-- -------------------------------------------------------------------------------------
-- 6. Cutover: have CoCo commit the new dynamic table to main -> GitHub Actions deploys
--    it to PROD. Then deploy the legacy teardown to drop the old task + target table.
-- -------------------------------------------------------------------------------------

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
