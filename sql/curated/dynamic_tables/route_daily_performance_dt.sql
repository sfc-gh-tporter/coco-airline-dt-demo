-- curated/dynamic_tables/route_daily_performance_dt.sql
-- Incremental route x day KPI dynamic table. Replaces the legacy full-recompute task
-- (curated.refresh_route_daily_performance_task) that rebuilds ROUTE_DAILY_PERFORMANCE.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE DYNAMIC TABLE AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT (
  route             COMMENT 'Origin-destination route code, e.g. JFK-LAX',
  flight_date       COMMENT 'Scheduled departure date of the flights on this route',
  seats_sold        COMMENT 'Bookings (seats sold) for the route on this date',
  revenue_usd       COMMENT 'Total booked fare revenue in USD for the route on this date',
  seat_capacity     COMMENT 'Total scheduled seat capacity on the route on this date',
  load_factor       COMMENT 'seats_sold / seat_capacity (0-1), rounded to 4 decimals',
  avg_delay_minutes COMMENT 'Average departure delay in minutes for the route-date',
  on_time_pct       COMMENT 'Percent of status events with delay <= 15 minutes (0-100)'
)
  TARGET_LAG   = '5 minutes'
  WAREHOUSE    = AIRLINE_DEMO_WH
  REFRESH_MODE = INCREMENTAL
  CLUSTER BY (flight_date)
  COMMENT      = 'Route x day performance KPIs (bookings, capacity, load factor, delays); incremental replacement for the legacy full-refresh task'
AS
WITH flight_delay AS (
  SELECT e.flight_id,
         AVG(e.payload:delay_minutes::NUMBER) AS avg_delay,
         AVG(CASE WHEN e.payload:delay_minutes::NUMBER <= 15 THEN 1 ELSE 0 END) AS on_time_ratio
  FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS e
  GROUP BY e.flight_id
),
bk AS (
  SELECT f.route, b.flight_date AS perf_date, COUNT(*) AS seats_sold, SUM(b.fare_usd) AS revenue_usd
  FROM AIRLINE_PROD.STAGING.BOOKINGS b
  JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = b.flight_id
  GROUP BY 1, 2
),
cap AS (
  SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date, SUM(f.seat_capacity) AS seat_capacity
  FROM AIRLINE_PROD.STAGING.FLIGHTS f
  GROUP BY 1, 2
),
dly AS (
  SELECT f.route, f.scheduled_dep_ts::DATE AS perf_date,
         AVG(fd.avg_delay) AS avg_delay_minutes, AVG(fd.on_time_ratio) * 100 AS on_time_pct
  FROM flight_delay fd
  JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = fd.flight_id
  GROUP BY 1, 2
)
SELECT bk.route, bk.perf_date AS flight_date, bk.seats_sold, bk.revenue_usd, cap.seat_capacity,
       ROUND(bk.seats_sold / NULLIF(cap.seat_capacity, 0), 4) AS load_factor,
       ROUND(dly.avg_delay_minutes, 2) AS avg_delay_minutes,
       ROUND(dly.on_time_pct, 2) AS on_time_pct
FROM bk
LEFT JOIN cap ON cap.route = bk.route AND cap.perf_date = bk.perf_date
LEFT JOIN dly ON dly.route = bk.route AND dly.perf_date = bk.perf_date;
