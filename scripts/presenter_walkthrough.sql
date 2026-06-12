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
-- The data: two ~1GB structured facts + one ~1GB VARIANT table, plus a small dim.
SHOW TABLES IN SCHEMA airline_prod.staging;

-- The plumbing the legacy pipeline needs: 3 append-only streams + an audit table.
SHOW STREAMS IN SCHEMA airline_prod.staging;
SELECT GET_DDL('PROCEDURE', 'airline_prod.curated.sp_rebuild_route_daily_performance()');
SELECT GET_DDL('TASK', 'airline_prod.curated.refresh_route_daily_performance_task');

-- The KPI consumers actually use:
SELECT * FROM airline_prod.curated.route_daily_performance ORDER BY revenue_usd DESC LIMIT 10;

-- -------------------------------------------------------------------------------------
-- 2. Show the cost of the anti-pattern: a FULL recompute over ALL history every run
-- -------------------------------------------------------------------------------------
-- Drop a tiny batch of brand-new bookings/events into staging...
CALL airline_prod.data_gen.sp_generate_airline_data(1.0, 'LIVE');

-- ...then resume the legacy task (or call the proc directly) and watch it rescan ~2GB
-- just to reflect a few hundred new rows.
ALTER TASK airline_prod.curated.refresh_route_daily_performance_task RESUME;

-- Inspect what the full recompute actually scanned (note bytes/time vs rows changed):
SELECT query_id, ROUND(total_elapsed_time/1000,1) AS secs,
       ROUND(bytes_scanned/POW(1024,3),2) AS gb_scanned, rows_produced
FROM TABLE(airline_prod.information_schema.query_history_by_session(RESULT_LIMIT=>50))
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
--   Use the /dynamic-tables skill to modernize the pipeline in the airline_prod_dev_cl
--   database. The staging schema feeds a curated route x day KPI table
--   (airline_prod_dev_cl.curated.route_daily_performance) today via append-only streams
--   plus a scheduled task that fully rebuilds the whole table on every run. Replace that
--   streams + task pattern with a single INCREMENTAL dynamic table in
--   airline_prod_dev_cl.curated that produces the same KPI columns. Confirm it refreshes
--   incrementally, then show me the DDL before creating anything.
-- -------------------------------------------------------------------------------------

-- -------------------------------------------------------------------------------------
-- 5. Validate CoCo's dynamic table in the clone
-- -------------------------------------------------------------------------------------
-- Discover what CoCo created and confirm refresh_mode = INCREMENTAL (not FULL):
SHOW DYNAMIC TABLES IN SCHEMA airline_prod_dev_cl.curated;

-- Prove incremental: drop a small batch into staging, then refresh the dynamic table.
INSERT INTO airline_prod_dev_cl.staging.bookings
  (booking_id, passenger_id, passenger_name, flight_id, flight_date, fare_usd, seat_class, channel, booking_ts)
SELECT airline_prod_dev_cl.data_gen.booking_seq.NEXTVAL, 1, 'Demo Passenger', f.flight_id,
       f.scheduled_dep_ts::DATE, 250, 'ECONOMY', 'WEB', f.scheduled_dep_ts
FROM airline_prod_dev_cl.staging.flights f LIMIT 200;

-- Substitute the dynamic table name CoCo chose:
ALTER DYNAMIC TABLE airline_prod_dev_cl.curated.<dt_name_coco_created> REFRESH;
-- The refresh statistics should show insertedRows ~= deletedRows with a large copiedRows
-- (only the affected route x day groups recomputed) -> incremental, not a full rebuild.

-- -------------------------------------------------------------------------------------
-- 6. Cutover: have CoCo commit the new dynamic table to main -> GitHub Actions deploys
--    it to PROD. Then deploy the legacy teardown to remove the old streams + task.
-- -------------------------------------------------------------------------------------
