-- DBT-Actions/sql/00_account/05_service_users.sql
-- GitHub Actions identities for the dbt DT demo: OIDC workload identity federation, so no
-- password, key or token is stored in GitHub. Requires ACCOUNTADMIN; one-time bootstrap.
--
-- Each OIDC service user needs a unique subject. The DT demo in the same repo already uses
-- `pull_request` and `environment:prod`, so both dbt jobs declare their own GitHub environment:
--   dbt-ci   (no reviewers)       -> svc_gh_dbt_ci      -> airline_dbt_ci_rl
--   dbt-prod (required reviewer)  -> svc_gh_dbt_deploy  -> airline_dbt_deploy_rl
-- Update the repo slug if you fork.

USE ROLE accountadmin;

CREATE USER IF NOT EXISTS svc_gh_dbt_ci
  TYPE = SERVICE
  DEFAULT_ROLE = airline_dbt_ci_rl
  DEFAULT_WAREHOUSE = airline_dbt_ci_wh
  COMMENT = 'GitHub Actions dbt demo CI identity (OIDC, environment:dbt-ci)';
ALTER USER svc_gh_dbt_ci SET WORKLOAD_IDENTITY = (
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:sfc-gh-tporter/coco-airline-dt-demo:environment:dbt-ci'
);
GRANT ROLE airline_dbt_ci_rl TO USER svc_gh_dbt_ci;

CREATE USER IF NOT EXISTS svc_gh_dbt_deploy
  TYPE = SERVICE
  DEFAULT_ROLE = airline_dbt_deploy_rl
  DEFAULT_WAREHOUSE = airline_dbt_wh
  COMMENT = 'GitHub Actions dbt demo PROD deploy identity (OIDC, environment:dbt-prod)';
ALTER USER svc_gh_dbt_deploy SET WORKLOAD_IDENTITY = (
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:sfc-gh-tporter/coco-airline-dt-demo:environment:dbt-prod'
);
GRANT ROLE airline_dbt_deploy_rl TO USER svc_gh_dbt_deploy;

-- Verify:
--   SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_dbt_ci;
--   SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_dbt_deploy;
