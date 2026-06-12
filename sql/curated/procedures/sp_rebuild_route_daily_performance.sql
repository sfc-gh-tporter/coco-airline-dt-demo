-- curated/procedures/sp_rebuild_route_daily_performance.sql
-- The inefficiency the demo replaces. Every run it:
--   1. consumes all three append-only streams ONLY to advance their offsets
--      (bookkeeping in PIPELINE_AUDIT) - the increment is then thrown away;
--   2. fully recomputes the ENTIRE mart over all history (~1GB+ bookings JOIN
--      ~1GB+ events JOIN flights) via INSERT OVERWRITE.
-- Cost/time grow with total data, not with what changed. The incremental
-- Dynamic Table replaces all of this.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE()
  RETURNS STRING
  LANGUAGE SQL
AS
$$
BEGIN
  -- 1) Consume streams purely to advance offsets (so SYSTEM$STREAM_HAS_DATA resets).
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'BOOKINGS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.BOOKINGS_STREAM;
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'FLIGHTS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.FLIGHTS_STREAM;
  INSERT INTO AIRLINE_PROD.STAGING.PIPELINE_AUDIT (source_object, rows_consumed)
    SELECT 'FLIGHT_STATUS_EVENTS_STREAM', COUNT(*) FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS_STREAM;

  -- 2) FULL RECOMPUTE of the whole mart over ALL history (the anti-pattern).
  INSERT OVERWRITE INTO AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE
    (route, flight_date, seats_sold, revenue_usd, seat_capacity,
     load_factor, avg_delay_minutes, on_time_pct, last_rebuilt_ts)
  WITH flight_delay AS (
    SELECT e.flight_id,
           AVG(e.payload:delay_minutes::NUMBER)                                AS avg_delay,
           AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
    FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS e
    GROUP BY e.flight_id
  ),
  bk AS (
    SELECT f.route, b.flight_date AS perf_date,
           COUNT(*)        AS seats_sold,
           SUM(b.fare_usd) AS revenue_usd
    FROM AIRLINE_PROD.STAGING.BOOKINGS b
    JOIN AIRLINE_PROD.STAGING.FLIGHTS  f ON f.flight_id = b.flight_id
    GROUP BY 1, 2
  ),
  cap AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date,
           SUM(f.seat_capacity) AS seat_capacity
    FROM AIRLINE_PROD.STAGING.FLIGHTS f
    GROUP BY 1, 2
  ),
  dly AS (
    SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date,
           AVG(fd.avg_delay)        AS avg_delay_minutes,
           AVG(fd.on_time_ratio)*100 AS on_time_pct
    FROM flight_delay fd
    JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = fd.flight_id
    GROUP BY 1, 2
  )
  SELECT
    bk.route,
    bk.perf_date,
    bk.seats_sold,
    bk.revenue_usd,
    cap.seat_capacity,
    ROUND(bk.seats_sold / NULLIF(cap.seat_capacity, 0), 4),
    ROUND(dly.avg_delay_minutes, 2),
    ROUND(dly.on_time_pct, 2),
    CURRENT_TIMESTAMP()
  FROM bk
  LEFT JOIN cap ON cap.route = bk.route AND cap.perf_date = bk.perf_date
  LEFT JOIN dly ON dly.route = bk.route AND dly.perf_date = bk.perf_date;

  RETURN 'Rebuilt ROUTE_DAILY_PERFORMANCE via full recompute';
END;
$$;
