-- object-parity-test / references/test-templates.sql
-- Parameterized templates the skill adapts to the two objects under test. Replace
-- {{CANDIDATE}} / {{INCUMBENT}} with fully-qualified names and {{COLS}} with the
-- comparable, non-volatile column list. Run in a dev/clone database.
-- =====================================================================================

-- 1) SCHEMA COMPARISON -----------------------------------------------------------------
DESCRIBE TABLE {{INCUMBENT}};
DESCRIBE TABLE {{CANDIDATE}};
-- Compare column name / type / order. Note intentional drops (e.g. volatile audit columns).

-- 2) ROW COUNTS ------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM {{INCUMBENT}}) AS incumbent_rows,
  (SELECT COUNT(*) FROM {{CANDIDATE}}) AS candidate_rows;

-- 3) SET EQUALITY (both directions; each EXCEPT parenthesized for correct precedence) ---
--    Empty result from BOTH = identical over the compared columns.
(
  SELECT 'in_incumbent_only' AS side, {{COLS}} FROM {{INCUMBENT}}
  EXCEPT
  SELECT 'in_incumbent_only' AS side, {{COLS}} FROM {{CANDIDATE}}
)
UNION ALL
(
  SELECT 'in_candidate_only' AS side, {{COLS}} FROM {{CANDIDATE}}
  EXCEPT
  SELECT 'in_candidate_only' AS side, {{COLS}} FROM {{INCUMBENT}}
);

-- Count-only variant (0 / 0 = PASS):
SELECT
  (SELECT COUNT(*) FROM (SELECT {{COLS}} FROM {{INCUMBENT}} EXCEPT SELECT {{COLS}} FROM {{CANDIDATE}})) AS in_incumbent_not_candidate,
  (SELECT COUNT(*) FROM (SELECT {{COLS}} FROM {{CANDIDATE}} EXCEPT SELECT {{COLS}} FROM {{INCUMBENT}})) AS in_candidate_not_incumbent;

-- 4) AGGREGATE RECONCILIATION (adapt measures; tolerance for float/rounding) -----------
WITH i AS (SELECT COUNT(*) c, SUM({{MEASURE}}) s FROM {{INCUMBENT}}),
     c AS (SELECT COUNT(*) c, SUM({{MEASURE}}) s FROM {{CANDIDATE}})
SELECT i.c AS inc_count, c.c AS cand_count,
       i.s AS inc_sum, c.s AS cand_sum,
       ABS(COALESCE(i.s,0) - COALESCE(c.s,0)) AS abs_diff,
       IFF(ABS(COALESCE(i.s,0) - COALESCE(c.s,0)) <= 0.01, 'PASS', 'FAIL') AS verdict
FROM i, c;

-- 5) INCREMENTAL-BEHAVIOR CHECK (dynamic table candidate only; run in a CLONE) ---------
SHOW DYNAMIC TABLES LIKE '<dt_name>' IN SCHEMA {{CANDIDATE_SCHEMA}};
--   confirm refresh_mode = INCREMENTAL

-- insert a small, localized batch into the relevant base table, then:
ALTER DYNAMIC TABLE {{CANDIDATE}} REFRESH;

-- bytes + action for the refresh (set DB context first):
SELECT h.refresh_action,
       ROUND(q.bytes_scanned/POW(1024,3),3) AS gb_scanned,
       ROUND(q.total_elapsed_time/1000,1)   AS secs,
       q.rows_produced
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => '{{CANDIDATE}}')) h
JOIN TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT=>500)) q ON q.query_id = h.query_id
WHERE h.refresh_action = 'INCREMENTAL'
ORDER BY h.refresh_start_time DESC
LIMIT 1;
-- PASS = refresh_action INCREMENTAL and rows_produced << total table rows (localized rewrite).
