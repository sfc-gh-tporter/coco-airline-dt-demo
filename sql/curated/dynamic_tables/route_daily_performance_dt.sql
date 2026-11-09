-- curated/dynamic_tables/route_daily_performance_dt.sql
-- Incremental replacement for the legacy full-recompute task + table
-- (CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK -> CURATED.ROUTE_DAILY_PERFORMANCE).
-- Same route x day KPI logic, but Snowflake maintains it incrementally: a refresh
-- only reprocesses the route x day groups touched by new bookings / flights / events.
--
-- Semantics are kept identical to the legacy query on purpose: delay and on-time
-- are averaged PER FLIGHT first, then averaged across the flights of a route-day
-- (flights have 63-166 events each, so a flat SUM/COUNT over events would drift).
-- REFRESH_MODE = INCREMENTAL (not AUTO) so the build fails loudly rather than
-- silently degrading to a full recompute.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE DYNAMIC TABLE AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT (
  route              COMMENT 'Route code, origin-dest (e.g. JFK-LAX)',
  flight_date        COMMENT 'Performance day: booking flight date for sales; scheduled departure date for capacity and delay',
  seats_sold         COMMENT 'Seats sold: count of bookings on the route and day',
  revenue_usd        COMMENT 'Booking revenue in USD: sum of fares on the route and day',
  seat_capacity      COMMENT 'Seats offered: sum of seat capacity of flights scheduled on the route and day',
  load_factor        COMMENT 'seats_sold / seat_capacity, rounded to 4 decimals',
  avg_delay_minutes  COMMENT 'Mean of per-flight average delay minutes across the flights of the route and day',
  on_time_pct        COMMENT 'Percent of flights on time (average delay ratio <= 15 min, per flight), 0-100'
)
  TARGET_LAG    = '5 minutes'
  WAREHOUSE     = AIRLINE_DEMO_WH
  REFRESH_MODE  = INCREMENTAL
  INITIALIZE    = ON_CREATE
  COMMENT       = 'Route x day performance KPI mart, incrementally maintained. Replaces the full-recompute CURATED.ROUTE_DAILY_PERFORMANCE task/table.'
AS
WITH flight_delay AS (
  SELECT e.flight_id,
         AVG(e.payload:delay_minutes::NUMBER)                                  AS avg_delay,
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
         AVG(fd.avg_delay)         AS avg_delay_minutes,
         AVG(fd.on_time_ratio)*100 AS on_time_pct
  FROM flight_delay fd
  JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = fd.flight_id
  GROUP BY 1, 2
)
SELECT
  bk.route,
  bk.perf_date                                           AS flight_date,
  bk.seats_sold,
  bk.revenue_usd,
  cap.seat_capacity,
  ROUND(bk.seats_sold / NULLIF(cap.seat_capacity, 0), 4) AS load_factor,
  ROUND(dly.avg_delay_minutes, 2)                        AS avg_delay_minutes,
  ROUND(dly.on_time_pct, 2)                              AS on_time_pct
FROM bk
LEFT JOIN cap ON cap.route = bk.route AND cap.perf_date = bk.perf_date
LEFT JOIN dly ON dly.route = bk.route AND dly.perf_date = bk.perf_date;
