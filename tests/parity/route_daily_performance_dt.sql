-- tests/parity/route_daily_performance_dt.sql
-- Parity test: candidate AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT (incremental
-- dynamic table) vs incumbent AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE (legacy
-- full-refresh table). Generated with the object-parity-test skill.
--
-- CI contract: every result row has CHECK_NAME, PASSED (boolean), DETAIL. CI runs this
-- against the PR's zero-copy clones (names rewritten to AIRLINE_CI.PR_<n>_*), never prod.
-- Comparable columns: all 8 (no volatile/audit columns in either object).

WITH cand AS (
  SELECT route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE_DT
),
inc AS (
  SELECT route, flight_date, seats_sold, revenue_usd, seat_capacity, load_factor, avg_delay_minutes, on_time_pct
  FROM AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE
),
counts AS (
  SELECT (SELECT COUNT(*) FROM cand) AS c_rows, (SELECT COUNT(*) FROM inc) AS i_rows
),
diff AS (
  SELECT (SELECT COUNT(*) FROM ((SELECT * FROM cand) EXCEPT (SELECT * FROM inc))) AS only_cand,
         (SELECT COUNT(*) FROM ((SELECT * FROM inc) EXCEPT (SELECT * FROM cand))) AS only_inc
),
agg AS (
  SELECT (SELECT SUM(seats_sold)  FROM cand) AS c_seats, (SELECT SUM(seats_sold)  FROM inc) AS i_seats,
         (SELECT SUM(revenue_usd) FROM cand) AS c_rev,   (SELECT SUM(revenue_usd) FROM inc) AS i_rev,
         (SELECT AVG(load_factor) FROM cand) AS c_lf,    (SELECT AVG(load_factor) FROM inc) AS i_lf
)
SELECT 'row_count' AS check_name, c_rows = i_rows AS passed,
       TO_VARCHAR(c_rows) || ' vs ' || TO_VARCHAR(i_rows) AS detail
FROM counts
UNION ALL
SELECT 'set_equality', only_cand = 0 AND only_inc = 0,
       'only in candidate ' || only_cand || ', only in incumbent ' || only_inc
FROM diff
UNION ALL
SELECT 'aggregates', c_seats = i_seats AND c_rev = i_rev AND ABS(c_lf - i_lf) < 0.000001,
       'seats ' || c_seats || '/' || i_seats || ', revenue ' || c_rev || '/' || i_rev
FROM agg;
