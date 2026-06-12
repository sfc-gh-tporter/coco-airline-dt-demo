-- 00_account/01_role.sql
-- Custom CI/CD role that OWNS all production AIRLINE_PROD objects.
-- Assumed by the GitHub Actions service user and by the presenter for management.
-- Requires ACCOUNTADMIN (role + account-level task grants). One-time admin step;
-- NOT part of the GitHub Actions deploy (the service user cannot create roles).

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS PROD_GH_ACTIONS_DEPLOY_RL
  COMMENT = 'Owns and deploys AIRLINE_PROD pipeline objects via GitHub Actions CI/CD';

-- Let SYSADMIN manage it and the presenter assume it locally.
GRANT ROLE PROD_GH_ACTIONS_DEPLOY_RL TO ROLE SYSADMIN;
GRANT ROLE PROD_GH_ACTIONS_DEPLOY_RL TO USER TPORTER;

-- Account-level privilege required for the role to run its scheduled task.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE PROD_GH_ACTIONS_DEPLOY_RL;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE PROD_GH_ACTIONS_DEPLOY_RL;
