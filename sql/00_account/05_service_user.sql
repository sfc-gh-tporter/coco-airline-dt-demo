-- 00_account/05_service_user.sql
-- PROD deploy identity for GitHub Actions. TYPE=SERVICE, authenticated with GitHub
-- OIDC (workload identity federation): no password, no key pair, no secret in GitHub.
-- Snowflake validates GitHub's short-lived OIDC token against the trust below.
--
-- SUBJECT: the prod deploy job sets `environment: prod`, so GitHub emits the
-- environment form of the subject. Only a job that passed the `prod` environment's
-- required-reviewer gate can obtain this identity. Update the repo slug if you fork.
--
-- Requires ACCOUNTADMIN. One-time bootstrap; NOT part of the CI/CD deploy.

USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS SVC_GH_ACTIONS_AIRLINE
  TYPE = SERVICE
  DEFAULT_ROLE = PROD_GH_ACTIONS_DEPLOY_RL
  DEFAULT_WAREHOUSE = AIRLINE_DEMO_WH
  COMMENT = 'GitHub Actions PROD deploy identity (OIDC, environment:prod)';

ALTER USER SVC_GH_ACTIONS_AIRLINE SET WORKLOAD_IDENTITY = (
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:sfc-gh-tporter/coco-airline-dt-demo:environment:prod'
);

GRANT ROLE PROD_GH_ACTIONS_DEPLOY_RL TO USER SVC_GH_ACTIONS_AIRLINE;

-- Verify:
--   SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER SVC_GH_ACTIONS_AIRLINE;
-- Revoke access: ALTER USER SVC_GH_ACTIONS_AIRLINE UNSET WORKLOAD_IDENTITY;
