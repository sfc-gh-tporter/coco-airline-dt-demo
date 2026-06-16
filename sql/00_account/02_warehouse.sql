-- 00_account/02_warehouse.sql
-- Dedicated warehouse for the airline pipeline + dynamic table refreshes.
-- SMALL: at ~10GB the legacy full recompute takes ~15-20s (visibly slow) while the
-- incremental Dynamic Table stays ~6s on the same compute.

USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS AIRLINE_DEMO_WH
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for AIRLINE_PROD pipeline and dynamic table refreshes';

-- If the warehouse already exists at a different size, enforce SMALL:
ALTER WAREHOUSE AIRLINE_DEMO_WH SET WAREHOUSE_SIZE = 'SMALL';

GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE AIRLINE_DEMO_WH
  TO ROLE PROD_GH_ACTIONS_DEPLOY_RL;
