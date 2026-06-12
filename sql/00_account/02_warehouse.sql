-- 00_account/02_warehouse.sql
-- Dedicated warehouse for the airline pipeline + dynamic table refreshes.
-- Kept XSMALL on purpose: the legacy full-recompute task is meant to look slow,
-- and the incremental Dynamic Table should still be fast on the same compute.

USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS AIRLINE_DEMO_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for AIRLINE_PROD pipeline and dynamic table refreshes';

GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE AIRLINE_DEMO_WH
  TO ROLE PROD_GH_ACTIONS_DEPLOY_RL;
