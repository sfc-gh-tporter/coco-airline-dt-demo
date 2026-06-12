-- scripts/reset.sql
-- Returns the environment to its pre-demo baseline. Run by CoCo (or in a worksheet)
-- after a demo. Bulk data (~1GB+/table) is PRESERVED - it is not regenerated.
--
-- What it does:
--   1. drops the dev clone (AIRLINE_PROD_DEV_CL)
--   2. drops the incremental Dynamic Table the demo created in prod
--   3. restores the legacy pipeline the demo's teardown removed
--      (streams, audit table, rebuild proc, target table, scheduled task - SUSPENDED)
--   4. repopulates the legacy KPI mart once
--
-- Git side (run separately): git reset --hard baseline-v1 && git push --force-with-lease origin main
-- The `solution` branch is never touched.
-- =====================================================================================

-- 1) Drop the dev clone --------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS AIRLINE_PROD_DEV_CL;

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;
USE WAREHOUSE AIRLINE_DEMO_WH;

-- 2) Drop the demo's Dynamic Table ---------------------------------------------------
DROP DYNAMIC TABLE IF EXISTS AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT;

-- 3) Restore the legacy pipeline -----------------------------------------------------
-- 3a) append-only streams (reset to empty offset)
CREATE OR REPLACE STREAM AIRLINE_PROD.STAGING.BOOKINGS_STREAM
  ON TABLE AIRLINE_PROD.STAGING.BOOKINGS APPEND_ONLY = TRUE
  COMMENT = 'Append-only change stream on STAGING.BOOKINGS';
CREATE OR REPLACE STREAM AIRLINE_PROD.STAGING.FLIGHTS_STREAM
  ON TABLE AIRLINE_PROD.STAGING.FLIGHTS APPEND_ONLY = TRUE
  COMMENT = 'Append-only change stream on STAGING.FLIGHTS';
CREATE OR REPLACE STREAM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS_STREAM
  ON TABLE AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS APPEND_ONLY = TRUE
  COMMENT = 'Append-only change stream on STAGING.FLIGHT_STATUS_EVENTS';

-- 3b) audit table
CREATE TABLE IF NOT EXISTS AIRLINE_PROD.STAGING.PIPELINE_AUDIT (
  run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), source_object VARCHAR(64), rows_consumed NUMBER(38,0)
) COMMENT = 'Audit log: rows consumed from each stream per legacy task run';

-- 3c) legacy target table
CREATE TABLE IF NOT EXISTS AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE (
  route VARCHAR(7), flight_date DATE, seats_sold NUMBER(38,0), revenue_usd NUMBER(18,2),
  seat_capacity NUMBER(38,0), load_factor NUMBER(9,4), avg_delay_minutes NUMBER(9,2),
  on_time_pct NUMBER(6,2), last_rebuilt_ts TIMESTAMP_NTZ
) COMMENT = 'Route x day performance KPI (legacy full-recompute target)';

-- 3d) full-recompute procedure
CREATE OR REPLACE PROCEDURE AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE()
  RETURNS STRING LANGUAGE SQL
AS
$$
BEGIN
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'BOOKINGS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.BOOKINGS_STREAM;
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'FLIGHTS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.FLIGHTS_STREAM;
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'FLIGHT_STATUS_EVENTS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS_STREAM;
  INSERT OVERWRITE INTO AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE
    (route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct, last_rebuilt_ts)
  WITH flight_delay AS (
    SELECT e.flight_id, AVG(e.payload:delay_minutes::NUMBER) AS avg_delay,
           AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
    FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS e GROUP BY e.flight_id
  ),
  bk AS (
    SELECT f.route, b.flight_date AS perf_date, COUNT(*) AS seats_sold, SUM(b.fare_usd) AS revenue_usd
    FROM AIRLINE_PROD.STAGING.BOOKINGS b JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = b.flight_id GROUP BY 1,2
  ),
  cap AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, SUM(f.seat_capacity) AS seat_capacity
    FROM AIRLINE_PROD.STAGING.FLIGHTS f GROUP BY 1,2
  ),
  dly AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, AVG(fd.avg_delay) AS avg_delay_minutes,
           AVG(fd.on_time_ratio)*100 AS on_time_pct
    FROM flight_delay fd JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = fd.flight_id GROUP BY 1,2
  )
  SELECT bk.route, bk.perf_date, bk.seats_sold, bk.revenue_usd, cap.seat_capacity,
         ROUND(bk.seats_sold / NULLIF(cap.seat_capacity,0),4), ROUND(dly.avg_delay_minutes,2),
         ROUND(dly.on_time_pct,2), CURRENT_TIMESTAMP()
  FROM bk
  LEFT JOIN cap ON cap.route=bk.route AND cap.perf_date=bk.perf_date
  LEFT JOIN dly ON dly.route=bk.route AND dly.perf_date=bk.perf_date;
  RETURN 'Rebuilt ROUTE_DAILY_PERFORMANCE via full recompute';
END;
$$;

-- 3e) scheduled task (created SUSPENDED)
CREATE OR REPLACE TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK
  WAREHOUSE = AIRLINE_DEMO_WH SCHEDULE = '5 MINUTE'
  COMMENT = 'Legacy: gated full recompute of ROUTE_DAILY_PERFORMANCE'
  WHEN SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.BOOKINGS_STREAM')
    OR SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS_STREAM')
    OR SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.FLIGHTS_STREAM')
AS CALL AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE();

-- 4) Repopulate the legacy mart once -------------------------------------------------
CALL AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE();

-- Done. Verify:
SHOW DYNAMIC TABLES IN SCHEMA AIRLINE_PROD.CURATED;          -- expect none
SHOW STREAMS IN SCHEMA AIRLINE_PROD.STAGING;                 -- expect 3
SHOW TASKS IN SCHEMA AIRLINE_PROD.CURATED;                   -- expect 1 (suspended)
