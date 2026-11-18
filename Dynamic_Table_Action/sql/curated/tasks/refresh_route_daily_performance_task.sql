-- curated/tasks/refresh_route_daily_performance_task.sql
-- Legacy scheduler (the anti-pattern). Every 10 minutes it FULLY recomputes the
-- entire route x day KPI mart from scratch (INSERT OVERWRITE over ALL history),
-- regardless of how little changed. The incremental Dynamic Table replaces this task.
-- DATABASE-RELATIVE body (schema-qualified) so a clone runs against its own data.
-- Created SUSPENDED; the presenter resumes it (or runs EXECUTE TASK) during the demo.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK
  WAREHOUSE = AIRLINE_DEMO_WH
  SCHEDULE  = '10 MINUTE'
  COMMENT   = 'Legacy: full recompute of ROUTE_DAILY_PERFORMANCE every 10 minutes'
AS
  INSERT OVERWRITE INTO CURATED.ROUTE_DAILY_PERFORMANCE
    (route, flight_date, seats_sold, revenue_usd, seat_capacity,
     load_factor, avg_delay_minutes, on_time_pct)
  WITH flight_delay AS (
    SELECT e.flight_id,
           AVG(e.payload:delay_minutes::NUMBER)                                  AS avg_delay,
           AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
    FROM STAGING.FLIGHT_STATUS_EVENTS e
    GROUP BY e.flight_id
  ),
  bk AS (
    SELECT f.route, b.flight_date AS perf_date,
           COUNT(*)        AS seats_sold,
           SUM(b.fare_usd) AS revenue_usd
    FROM STAGING.BOOKINGS b
    JOIN STAGING.FLIGHTS  f ON f.flight_id = b.flight_id
    GROUP BY 1, 2
  ),
  cap AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date,
           SUM(f.seat_capacity) AS seat_capacity
    FROM STAGING.FLIGHTS f
    GROUP BY 1, 2
  ),
  dly AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date,
           AVG(fd.avg_delay)         AS avg_delay_minutes,
           AVG(fd.on_time_ratio)*100 AS on_time_pct
    FROM flight_delay fd
    JOIN STAGING.FLIGHTS f ON f.flight_id = fd.flight_id
    GROUP BY 1, 2
  )
  SELECT
    bk.route, bk.perf_date, bk.seats_sold, bk.revenue_usd, cap.seat_capacity,
    ROUND(bk.seats_sold / NULLIF(cap.seat_capacity, 0), 4),
    ROUND(dly.avg_delay_minutes, 2),
    ROUND(dly.on_time_pct, 2)
  FROM bk
  LEFT JOIN cap ON cap.route = bk.route AND cap.perf_date = bk.perf_date
  LEFT JOIN dly ON dly.route = bk.route AND dly.perf_date = bk.perf_date;

-- Run it during the demo:
--   ALTER TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK RESUME;
--   EXECUTE TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK;  -- run now
-- Note: task body is schema-qualified, so the cloned copy in a dev clone rebuilds the
-- clone's own CURATED.ROUTE_DAILY_PERFORMANCE from the clone's STAGING when resumed.
