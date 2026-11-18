-- object-parity-test / references/test-templates.sql
-- Parameterized templates the skill adapts to the two objects under test. Replace
-- {{CANDIDATE}} / {{INCUMBENT}} with fully-qualified sandbox names, {{COLS}} with the
-- comparable, non-volatile column list and {{SANDBOX}} with <DEV_DB>.<DEV_SCHEMA>.
-- Everything here runs in the developer sandbox (zero-copy clones), never in prod.
-- =====================================================================================

-- 1) SCHEMA COMPARISON -----------------------------------------------------------------
DESCRIBE TABLE {{INCUMBENT}};
DESCRIBE TABLE {{CANDIDATE}};

-- 2) ROW COUNTS ------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM {{INCUMBENT}}) AS incumbent_rows,
  (SELECT COUNT(*) FROM {{CANDIDATE}}) AS candidate_rows;

-- 3) SET EQUALITY (both directions; each EXCEPT parenthesized) -------------------------
--    0 / 0 = identical over the compared columns.
SELECT
  (SELECT COUNT(*) FROM (SELECT {{COLS}} FROM {{INCUMBENT}} EXCEPT SELECT {{COLS}} FROM {{CANDIDATE}})) AS in_incumbent_not_candidate,
  (SELECT COUNT(*) FROM (SELECT {{COLS}} FROM {{CANDIDATE}} EXCEPT SELECT {{COLS}} FROM {{INCUMBENT}})) AS in_candidate_not_incumbent;

-- 4) AGGREGATE RECONCILIATION (adapt measures; tolerance for rounding) ----------------
WITH i AS (SELECT COUNT(*) c, SUM({{MEASURE}}) s FROM {{INCUMBENT}}),
     c AS (SELECT COUNT(*) c, SUM({{MEASURE}}) s FROM {{CANDIDATE}})
SELECT i.s AS inc_sum, c.s AS cand_sum,
       IFF(ABS(COALESCE(i.s,0) - COALESCE(c.s,0)) <= 0.01, 'PASS', 'FAIL') AS verdict
FROM i, c;

-- 5) INCREMENTAL-BEHAVIOR CHECK (dynamic table candidate only) -------------------------
SHOW DYNAMIC TABLES LIKE '<candidate_name>' IN SCHEMA {{SANDBOX}};
--   confirm refresh_mode = INCREMENTAL and refresh_mode_reason is empty

-- Localized batch into the sandbox clone of a base table: copy a few hundred recent
-- rows with new keys and a fresh timestamp (adapt table/columns to the change).
INSERT INTO {{SANDBOX}}.<base_table> (<cols>)
SELECT <key> + 10000000000, <other cols>, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM {{SANDBOX}}.<base_table>
WHERE <date_col> >= CURRENT_DATE() AND <date_col> < DATEADD('day', 7, CURRENT_DATE())
LIMIT 400;

ALTER DYNAMIC TABLE {{CANDIDATE}} REFRESH;   -- statistics column: insertedRows / deletedRows

SELECT refresh_action, state,
       DATEDIFF('millisecond', refresh_start_time, refresh_end_time) / 1000 AS secs
FROM TABLE(<DEV_DB>.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => '{{CANDIDATE}}'))
WHERE refresh_trigger = 'MANUAL'
ORDER BY refresh_start_time DESC
LIMIT 1;
-- PASS = refresh_action INCREMENTAL and rows rewritten << total table rows.
