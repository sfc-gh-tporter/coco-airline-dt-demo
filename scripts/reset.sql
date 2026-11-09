-- scripts/reset.sql
-- Returns Snowflake to its pre-demo baseline. Run after a demo:
--     snow sql -f scripts/reset.sql -c <connection>
-- Bulk data (~10GB) is PRESERVED, not regenerated.
--
-- What it does:
--   1. drops every pull-request test schema in AIRLINE_CI (PR_<n>_*)
--   2. drops the incremental Dynamic Table the demo deployed to prod
--   3. empties the prod deploy audit log (AIRLINE_PROD.OPS.DEPLOY_LOG)
--   4. restores the legacy pipeline (target table + the full-recompute task, SUSPENDED)
--   5. repopulates the legacy KPI mart once
--
-- GitHub side (run separately): bash scripts/reset_git.sh
-- The `solution` branch is never touched.
-- =====================================================================================

-- 1) Drop all PR test environments -------------------------------------------------
USE ROLE airline_ci_rl;
EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR SELECT schema_name FROM airline_ci.information_schema.schemata
               WHERE schema_name LIKE 'PR\\_%';
  n INTEGER DEFAULT 0;
BEGIN
  FOR r IN c DO
    EXECUTE IMMEDIATE 'DROP SCHEMA IF EXISTS airline_ci.' || r.schema_name;
    n := n + 1;
  END FOR;
  RETURN 'dropped ' || n || ' PR schema(s)';
END;
$$;

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;
USE WAREHOUSE airline_demo_wh;

-- 2) Drop the demo's Dynamic Table ---------------------------------------------------
DROP DYNAMIC TABLE IF EXISTS airline_prod.curated.route_daily_performance_dt;

-- 3) Empty the deploy audit log -------------------------------------------------------
TRUNCATE TABLE IF EXISTS airline_prod.ops.deploy_log;

-- 4) Restore the legacy pipeline -----------------------------------------------------
-- 4a) legacy target table
CREATE TABLE IF NOT EXISTS airline_prod.curated.route_daily_performance (
  route VARCHAR(7), flight_date DATE, seats_sold NUMBER(38,0), revenue_usd NUMBER(18,2),
  seat_capacity NUMBER(38,0), load_factor NUMBER(9,4), avg_delay_minutes NUMBER(9,2),
  on_time_pct NUMBER(6,2)
) CLUSTER BY (flight_date) COMMENT = 'Route x day performance KPI (legacy full-recompute target)';

-- 4b) legacy full-recompute task (created SUSPENDED), recompute inlined
CREATE OR REPLACE TASK airline_prod.curated.refresh_route_daily_performance_task
  WAREHOUSE = airline_demo_wh
  SCHEDULE  = '10 MINUTE'
  COMMENT   = 'Legacy: full recompute of ROUTE_DAILY_PERFORMANCE every 10 minutes'
AS
  INSERT OVERWRITE INTO airline_prod.curated.route_daily_performance
    (route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct)
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
         ROUND(dly.on_time_pct,2)
  FROM bk
  LEFT JOIN cap ON cap.route=bk.route AND cap.perf_date=bk.perf_date
  LEFT JOIN dly ON dly.route=bk.route AND dly.perf_date=bk.perf_date;

-- 5) Repopulate the legacy mart once (run the same recompute directly) ---------------
INSERT OVERWRITE INTO airline_prod.curated.route_daily_performance
  (route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct)
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
       ROUND(dly.on_time_pct,2)
FROM bk
LEFT JOIN cap ON cap.route=bk.route AND cap.perf_date=bk.perf_date
LEFT JOIN dly ON dly.route=bk.route AND dly.perf_date=bk.perf_date;

-- Done. Verify:
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;      -- expect none
SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;   -- expect none
SHOW TASKS IN SCHEMA airline_prod.curated;            -- expect 1 (suspended)
SELECT COUNT(*) AS mart_rows FROM airline_prod.curated.route_daily_performance;
