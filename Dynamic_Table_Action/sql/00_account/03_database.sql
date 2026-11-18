-- 00_account/03_database.sql
-- Production database. Created by SYSADMIN, then ownership handed to the CI/CD
-- role so every object underneath is owned by PROD_GH_ACTIONS_DEPLOY_RL.

USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS AIRLINE_PROD
  COMMENT = 'Production airline pipeline demo (CoCo). Owned by PROD_GH_ACTIONS_DEPLOY_RL.';

GRANT OWNERSHIP ON DATABASE AIRLINE_PROD
  TO ROLE PROD_GH_ACTIONS_DEPLOY_RL COPY CURRENT GRANTS;
