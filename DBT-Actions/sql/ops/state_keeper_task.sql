-- DBT-Actions/sql/ops/state_keeper_task.sql
-- Slim CI imports prod state with SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET, which only looks
-- back 14 days. A daily `dbt compile` (no warehouse work on the DAG) keeps that state fresh
-- even when nothing has been deployed for a while.

USE ROLE airline_dbt_deploy_rl;

CREATE OR ALTER TASK airline_dbt_prod.ops.dbt_state_keeper
  WAREHOUSE = airline_dbt_wh
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  COMMENT = 'Daily dbt compile so Slim CI always has prod state (< 14 days old)'
AS
  EXECUTE DBT PROJECT airline_dbt_prod.dbt.airline_dbt_prod_project ARGS = 'compile --target prod';

ALTER TASK airline_dbt_prod.ops.dbt_state_keeper RESUME;
