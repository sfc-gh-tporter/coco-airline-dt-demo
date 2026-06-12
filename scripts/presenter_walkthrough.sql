-- scripts/presenter_walkthrough.sql
-- Step-2 live demo script. Run section by section with the customer. This file is
-- a presenter aid; it is NOT deployed by GitHub Actions.
-- =====================================================================================

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;
USE WAREHOUSE AIRLINE_DEMO_WH;

-- -------------------------------------------------------------------------------------
-- 1. Tour the existing (inefficient) pipeline
-- -------------------------------------------------------------------------------------
-- The data: two ~1GB structured facts + one ~1GB VARIANT table, plus a small dim.
SHOW TABLES IN SCHEMA AIRLINE_PROD.STAGING;

-- The plumbing the legacy pipeline needs: 3 append-only streams + an audit table.
SHOW STREAMS IN SCHEMA AIRLINE_PROD.STAGING;
SELECT GET_DDL('PROCEDURE', 'AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE()');
SELECT GET_DDL('TASK', 'AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK');

-- The KPI consumers actually use:
SELECT * FROM AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE ORDER BY revenue_usd DESC LIMIT 10;

-- -------------------------------------------------------------------------------------
-- 2. Show the cost of the anti-pattern: a FULL recompute over ALL history every run
-- -------------------------------------------------------------------------------------
-- Drop a tiny batch of brand-new bookings/events into staging...
CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'LIVE');

-- ...then resume the legacy task (or call the proc directly) and watch it rescan ~2GB
-- just to reflect a few hundred new rows.
ALTER TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK RESUME;

-- Inspect what the full recompute actually scanned (note bytes/time vs rows changed):
SELECT query_id, ROUND(total_elapsed_time/1000,1) AS secs,
       ROUND(bytes_scanned/POW(1024,3),2) AS gb_scanned, rows_produced
FROM TABLE(AIRLINE_PROD.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT=>50))
WHERE query_text ILIKE 'INSERT OVERWRITE INTO AIRLINE_PROD.CURATED%'
ORDER BY start_time DESC LIMIT 3;

-- Suspend it again before the clone step.
ALTER TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK SUSPEND;

-- -------------------------------------------------------------------------------------
-- 3. Clone production to a safe dev sandbox (zero-copy, instant)
-- -------------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE DATABASE AIRLINE_PROD_DEV_CL CLONE AIRLINE_PROD;
GRANT OWNERSHIP ON DATABASE AIRLINE_PROD_DEV_CL TO ROLE PROD_GH_ACTIONS_DEPLOY_RL COPY CURRENT GRANTS;
USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

-- -------------------------------------------------------------------------------------
-- 4. >>> Hand off to CoCo <<<
--    "Use the /dynamic-tables skill to convert this streams + task pipeline into a
--     single INCREMENTAL dynamic table in AIRLINE_PROD_DEV_CL.CURATED."
--    (The validated answer lives in sql/curated/dynamic_tables/route_daily_performance_dt.sql,
--     also on the `solution` branch as a cherry-pick safety net.)
-- -------------------------------------------------------------------------------------

-- 5. Validate in the clone: confirm INCREMENTAL and that refresh touches only changed rows.
SHOW DYNAMIC TABLES LIKE 'ROUTE_DAILY_PERFORMANCE_DT' IN SCHEMA AIRLINE_PROD_DEV_CL.CURATED;
-- (check refresh_mode = INCREMENTAL)
INSERT INTO AIRLINE_PROD_DEV_CL.STAGING.BOOKINGS
  (booking_id, passenger_id, passenger_name, flight_id, flight_date, fare_usd, seat_class, channel, booking_ts)
SELECT AIRLINE_PROD_DEV_CL.DATA_GEN.BOOKING_SEQ.NEXTVAL, 1, 'Demo Passenger', f.flight_id,
       f.scheduled_dep_ts::DATE, 250, 'ECONOMY', 'WEB', f.scheduled_dep_ts
FROM AIRLINE_PROD_DEV_CL.STAGING.FLIGHTS f LIMIT 200;
ALTER DYNAMIC TABLE AIRLINE_PROD_DEV_CL.CURATED.ROUTE_DAILY_PERFORMANCE_DT REFRESH;
-- statistics show insertedRows ~= deletedRows and a large copiedRows -> incremental.

-- 6. Cutover: commit the DT (and teardown) to main -> GitHub Actions deploys to PROD.
--    Then deploy sql/teardown/decommission_legacy_pipeline.sql to remove the old pipeline.
