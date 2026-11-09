-- curated/dynamic_tables/route_daily_performance_dt.sql
-- Route x day KPI mart as an INCREMENTAL dynamic table. Replaces the legacy
-- refresh_route_daily_performance_task, which fully recomputes
-- curated.route_daily_performance every 10 minutes regardless of how little changed.
-- The dynamic table refreshes only the affected route/day groups (5 minute target lag).

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE DYNAMIC TABLE AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT (
  route             COMMENT 'Route code from flights (origin-destination); grain key with flight_date.',
  flight_date       COMMENT 'Flight date from bookings; grain key with route.',
  seats_sold        COMMENT 'Count of bookings for the route and date.',
  revenue_usd       COMMENT 'Sum of booking fare_usd (USD) for the route and date.',
  seat_capacity     COMMENT 'Sum of seat_capacity over flights scheduled to depart on the route and date.',
  load_factor       COMMENT 'seats_sold / seat_capacity, rounded to 4 decimals; NULL if capacity is 0 or missing.',
  avg_delay_minutes COMMENT 'Mean of per-flight average payload delay_minutes from status events, rounded to 2 decimals.',
  on_time_pct       COMMENT 'Percent of status events with delay_minutes <= 15, averaged per flight then across flights, rounded to 2 decimals.'
)
  TARGET_LAG   = '5 minutes'
  WAREHOUSE    = AIRLINE_DEMO_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT      = 'Daily route KPI mart: seats sold, revenue, capacity, load factor and delay metrics per route and flight date. Incremental dynamic table replacing the full-recompute task refresh_route_daily_performance_task.'
AS
WITH flight_delay AS (
  SELECT e.flight_id,
         AVG(e.payload:delay_minutes::NUMBER)                                  AS avg_delay,
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
         AVG(fd.avg_delay)            AS avg_delay_minutes,
         AVG(fd.on_time_ratio) * 100  AS on_time_pct
  FROM flight_delay fd
  JOIN AIRLINE_PROD.STAGING.FLIGHTS f ON f.flight_id = fd.flight_id
  GROUP BY 1, 2
)
SELECT bk.route,
       bk.perf_date AS flight_date,
       bk.seats_sold,
       bk.revenue_usd,
       cap.seat_capacity,
       ROUND(bk.seats_sold / NULLIF(cap.seat_capacity, 0), 4) AS load_factor,
       ROUND(dly.avg_delay_minutes, 2)                        AS avg_delay_minutes,
       ROUND(dly.on_time_pct, 2)                              AS on_time_pct
FROM bk
LEFT JOIN cap ON cap.route = bk.route AND cap.perf_date = bk.perf_date
LEFT JOIN dly ON dly.route = bk.route AND dly.perf_date = bk.perf_date;
