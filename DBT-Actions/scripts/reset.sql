-- DBT-Actions/scripts/reset.sql
-- Snowflake side of the dbt demo reset (scripts/reset.sh runs this, then rebuilds the prod
-- slice from the baseline code). Bulk raw data is preserved. Never touches the DT demo.
--   1. drop the presenter dev clone and any leftover PR clones
--   2. empty the deploy log

USE ROLE airline_dbt_deploy_rl;   -- inherits airline_dbt_ci_rl, which owns the clones

EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR SELECT database_name FROM snowflake.information_schema.databases
               WHERE REGEXP_LIKE(database_name, 'AIRLINE_DBT_(DEV(_[A-Z0-9_]+)?|PR_[0-9]+)');
  n INTEGER DEFAULT 0;
BEGIN
  FOR r IN c DO
    EXECUTE IMMEDIATE 'DROP DATABASE IF EXISTS ' || r.database_name;
    n := n + 1;
  END FOR;
  RETURN 'dropped ' || n || ' dev / PR clone database(s)';
END;
$$;

TRUNCATE TABLE IF EXISTS airline_dbt_prod.ops.deploy_log;
