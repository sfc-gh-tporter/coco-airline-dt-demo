-- scripts/reset.sql
-- Returns the environment to its pre-demo baseline. Run after a demo (via the SQL
-- connection or a worksheet). Bulk data (~1GB+/table) is PRESERVED, not regenerated.
--
-- What it does:
--   1. drops the dev clone (AIRLINE_PROD_DEV_CL)
--   2. drops the incremental Dynamic Table the demo created in prod
--   3. restores the legacy pipeline (target table + the full-recompute task, SUSPENDED)
--   4. repopulates the legacy KPI mart once
--
-- Git side (run separately): git reset --hard baseline-v1 && git push --force-with-lease origin main
-- The `solution` branch is never touched.
-- =====================================================================================

-- 1) Drop the dev clone --------------------------------------------------------------
USE ROLE sysadmin;
DROP DATABASE IF EXISTS airline_prod_dev_cl;

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;
USE WAREHOUSE airline_demo_wh;

-- 2) Drop the demo's Dynamic Table ---------------------------------------------------
DROP DYNAMIC TABLE IF EXISTS airline_prod.curated.route_daily_performance_dt;

-- 3) Restore the legacy pipeline -----------------------------------------------------
-- 3a) legacy target table
CREATE TABLE IF NOT EXISTS airline_prod.curated.route_daily_performance (
  route VARCHAR(7), flight_date DATE, seats_sold NUMBER(38,0), revenue_usd NUMBER(18,2),
  seat_capacity NUMBER(38,0), load_factor NUMBER(9,4), avg_delay_minutes NUMBER(9,2),
  on_time_pct NUMBER(6,2), last_rebuilt_ts TIMESTAMP_NTZ
) COMMENT = 'Route x day performance KPI (legacy full-recompute target)';

-- 3b) legacy full-recompute task (created SUSPENDED), recompute inlined
CREATE OR REPLACE TASK airline_prod.curated.refresh_route_daily_performance_task
  WAREHOUSE = airline_demo_wh
  SCHEDULE  = '5 MINUTE'
  COMMENT   = 'Legacy: full recompute of ROUTE_DAILY_PERFORMANCE every 5 minutes'
AS
  INSERT OVERWRITE INTO airline_prod.curated.route_daily_performance
    (route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct, last_rebuilt_ts)
  WITH flight_delay AS (
    SELECT e.flight_id, AVG(e.payload:delay_minutes::NUMBER) AS avg_delay,
           AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
    FROM airline_prod.staging.flight_status_events e GROUP BY e.flight_id
  ),
  bk AS (
    SELECT f.route, b.flight_date AS perf_date, COUNT(*) AS seats_sold, SUM(b.fare_usd) AS revenue_usd
    FROM airline_prod.staging.bookings b JOIN airline_prod.staging.flights f ON f.flight_id = b.flight_id GROUP BY 1,2
  ),
  cap AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, SUM(f.seat_capacity) AS seat_capacity
    FROM airline_prod.staging.flights f GROUP BY 1,2
  ),
  dly AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, AVG(fd.avg_delay) AS avg_delay_minutes,
           AVG(fd.on_time_ratio)*100 AS on_time_pct
    FROM flight_delay fd JOIN airline_prod.staging.flights f ON f.flight_id = fd.flight_id GROUP BY 1,2
  )
  SELECT bk.route, bk.perf_date, bk.seats_sold, bk.revenue_usd, cap.seat_capacity,
         ROUND(bk.seats_sold / NULLIF(cap.seat_capacity,0),4), ROUND(dly.avg_delay_minutes,2),
         ROUND(dly.on_time_pct,2), CURRENT_TIMESTAMP()
  FROM bk
  LEFT JOIN cap ON cap.route=bk.route AND cap.perf_date=bk.perf_date
  LEFT JOIN dly ON dly.route=bk.route AND dly.perf_date=bk.perf_date;

-- 4) Repopulate the legacy mart once (run the same recompute directly) ---------------
INSERT OVERWRITE INTO airline_prod.curated.route_daily_performance
  (route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct, last_rebuilt_ts)
WITH flight_delay AS (
  SELECT e.flight_id, AVG(e.payload:delay_minutes::NUMBER) AS avg_delay,
         AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
  FROM airline_prod.staging.flight_status_events e GROUP BY e.flight_id
),
bk AS (
  SELECT f.route, b.flight_date AS perf_date, COUNT(*) AS seats_sold, SUM(b.fare_usd) AS revenue_usd
  FROM airline_prod.staging.bookings b JOIN airline_prod.staging.flights f ON f.flight_id = b.flight_id GROUP BY 1,2
),
cap AS (
  SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, SUM(f.seat_capacity) AS seat_capacity
  FROM airline_prod.staging.flights f GROUP BY 1,2
),
dly AS (
  SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, AVG(fd.avg_delay) AS avg_delay_minutes,
         AVG(fd.on_time_ratio)*100 AS on_time_pct
  FROM flight_delay fd JOIN airline_prod.staging.flights f ON f.flight_id = fd.flight_id GROUP BY 1,2
)
SELECT bk.route, bk.perf_date, bk.seats_sold, bk.revenue_usd, cap.seat_capacity,
       ROUND(bk.seats_sold / NULLIF(cap.seat_capacity,0),4), ROUND(dly.avg_delay_minutes,2),
       ROUND(dly.on_time_pct,2), CURRENT_TIMESTAMP()
FROM bk
LEFT JOIN cap ON cap.route=bk.route AND cap.perf_date=bk.perf_date
LEFT JOIN dly ON dly.route=bk.route AND dly.perf_date=bk.perf_date;

-- Done. Verify:
SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;   -- expect none
SHOW TASKS IN SCHEMA airline_prod.curated;            -- expect 1 (suspended)
SELECT COUNT(*) AS mart_rows FROM airline_prod.curated.route_daily_performance;
