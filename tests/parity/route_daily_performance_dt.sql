-- tests/parity/route_daily_performance_dt.sql
-- Parity: AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT (candidate, incremental dynamic table)
--     vs  AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE    (incumbent, full-recompute task target)
-- Comparable columns: all 8 KPI columns. No volatile columns (no load/audit timestamps).
-- Read-only; CI rewrites both names to the PR's zero-copy clones.

WITH cand AS (
  SELECT route, flight_date, seats_sold, revenue_usd, seat_capacity,
         load_factor, avg_delay_minutes, on_time_pct
  FROM AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT
),
inc AS (
  SELECT route, flight_date, seats_sold, revenue_usd, seat_capacity,
         load_factor, avg_delay_minutes, on_time_pct
  FROM AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE
),
cand_only AS (SELECT * FROM cand EXCEPT SELECT * FROM inc),
inc_only  AS (SELECT * FROM inc  EXCEPT SELECT * FROM cand),
cand_agg AS (
  SELECT COUNT(*) AS n,
         SUM(seats_sold) AS seats_sold, SUM(revenue_usd) AS revenue_usd,
         SUM(seat_capacity) AS seat_capacity, SUM(load_factor) AS load_factor,
         SUM(avg_delay_minutes) AS avg_delay_minutes, SUM(on_time_pct) AS on_time_pct,
         MIN(flight_date) AS min_date, MAX(flight_date) AS max_date
  FROM cand
),
inc_agg AS (
  SELECT COUNT(*) AS n,
         SUM(seats_sold) AS seats_sold, SUM(revenue_usd) AS revenue_usd,
         SUM(seat_capacity) AS seat_capacity, SUM(load_factor) AS load_factor,
         SUM(avg_delay_minutes) AS avg_delay_minutes, SUM(on_time_pct) AS on_time_pct,
         MIN(flight_date) AS min_date, MAX(flight_date) AS max_date
  FROM inc
),
cand_dup AS (
  SELECT COUNT(*) AS n FROM (SELECT route, flight_date FROM cand GROUP BY 1, 2 HAVING COUNT(*) > 1)
)
SELECT 'row_count' AS check_name,
       c.n = i.n AS passed,
       'candidate=' || c.n || ' incumbent=' || i.n AS detail
FROM cand_agg c, inc_agg i
UNION ALL
SELECT 'grain_unique_route_day',
       d.n = 0,
       d.n || ' duplicated route/day keys in candidate'
FROM cand_dup d
UNION ALL
SELECT 'set_equality_candidate_minus_incumbent',
       (SELECT COUNT(*) FROM cand_only) = 0,
       (SELECT COUNT(*) FROM cand_only) || ' candidate rows not in incumbent'
UNION ALL
SELECT 'set_equality_incumbent_minus_candidate',
       (SELECT COUNT(*) FROM inc_only) = 0,
       (SELECT COUNT(*) FROM inc_only) || ' incumbent rows not in candidate'
UNION ALL
SELECT 'aggregates',
       c.min_date IS NOT DISTINCT FROM i.min_date
         AND c.max_date IS NOT DISTINCT FROM i.max_date
         AND ABS(c.seats_sold        - i.seats_sold)        = 0
         AND ABS(c.seat_capacity     - i.seat_capacity)     = 0
         AND ABS(c.revenue_usd       - i.revenue_usd)       <= 0.01
         AND ABS(c.load_factor       - i.load_factor)       <= 0.01
         AND ABS(c.avg_delay_minutes - i.avg_delay_minutes) <= 0.01
         AND ABS(c.on_time_pct       - i.on_time_pct)       <= 0.01,
       'seats_sold ' || c.seats_sold || '/' || i.seats_sold
         || ', revenue ' || c.revenue_usd || '/' || i.revenue_usd
         || ', capacity ' || c.seat_capacity || '/' || i.seat_capacity
         || ' (candidate/incumbent)'
FROM cand_agg c, inc_agg i;
