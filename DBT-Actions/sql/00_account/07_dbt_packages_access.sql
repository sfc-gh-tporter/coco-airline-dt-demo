-- DBT-Actions/sql/00_account/07_dbt_packages_access.sql
-- Outbound access so dbt can install packages (dbt_utils) from the dbt package hub. When a
-- dbt project object has an external access integration, Snowflake runs `dbt deps` at deploy
-- time. The network rule lives outside AIRLINE_DBT_PROD so it is not copied into clones.
-- Requires ACCOUNTADMIN (CREATE INTEGRATION).

USE ROLE sysadmin;
CREATE DATABASE IF NOT EXISTS airline_dbt_admin COMMENT = 'dbt DT demo: account-level helpers (not cloned)';
CREATE SCHEMA IF NOT EXISTS airline_dbt_admin.network;

CREATE OR REPLACE NETWORK RULE airline_dbt_admin.network.dbt_package_hosts
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com', 'github.com');

USE ROLE accountadmin;
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION airline_dbt_pkg_eai
  ALLOWED_NETWORK_RULES = (airline_dbt_admin.network.dbt_package_hosts)
  ENABLED = TRUE
  COMMENT = 'dbt DT demo: dbt deps from hub.getdbt.com / GitHub';

GRANT USAGE ON INTEGRATION airline_dbt_pkg_eai TO ROLE airline_dbt_deploy_rl;
GRANT USAGE ON INTEGRATION airline_dbt_pkg_eai TO ROLE airline_dbt_ci_rl;
