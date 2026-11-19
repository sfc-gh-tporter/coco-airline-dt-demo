-- DBT-Actions/sql/00_account/02_warehouses.sql
-- Compute for the dbt DT demo. One-time bootstrap.
--   airline_dbt_wh       SMALL   prod refreshes + presenter dev builds
--   airline_dbt_ci_wh    XSMALL  PR slice builds (only the changed models and their downstream)
--   airline_dbt_init_wh  MEDIUM  used only as INITIALIZATION_WAREHOUSE when a slice is recreated

USE ROLE sysadmin;

CREATE WAREHOUSE IF NOT EXISTS airline_dbt_wh
  WAREHOUSE_SIZE = 'SMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt DT demo: prod refreshes and dev builds';
CREATE WAREHOUSE IF NOT EXISTS airline_dbt_ci_wh
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt DT demo: PR slice builds';
CREATE WAREHOUSE IF NOT EXISTS airline_dbt_init_wh
  WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt DT demo: dynamic table (re)initialization only';

GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE airline_dbt_wh      TO ROLE airline_dbt_deploy_rl;
GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE airline_dbt_init_wh TO ROLE airline_dbt_deploy_rl;
GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE airline_dbt_ci_wh   TO ROLE airline_dbt_ci_rl;
-- The presenter's dev clone is owned by the CI role and builds on the SMALL warehouse.
GRANT USAGE ON WAREHOUSE airline_dbt_wh TO ROLE airline_dbt_ci_rl;
