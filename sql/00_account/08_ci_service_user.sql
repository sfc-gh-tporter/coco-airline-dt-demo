-- 00_account/08_ci_service_user.sql
-- PR-check identity for GitHub Actions. TYPE=SERVICE, OIDC (workload identity
-- federation). Trusts GitHub's `pull_request` subject, so ONLY pull-request jobs of
-- this repo can log in as it - and it holds AIRLINE_CI_RL (no write access to prod).
-- Fork PRs never receive an OIDC token, so outside forks cannot reach Snowflake.
--
-- Requires ACCOUNTADMIN. One-time bootstrap; NOT part of the CI/CD deploy.

USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS SVC_GH_ACTIONS_CI
  TYPE = SERVICE
  DEFAULT_ROLE = AIRLINE_CI_RL
  DEFAULT_WAREHOUSE = AIRLINE_CI_WH
  COMMENT = 'GitHub Actions PR checks identity (OIDC, pull_request)';

ALTER USER SVC_GH_ACTIONS_CI SET WORKLOAD_IDENTITY = (
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:sfc-gh-tporter/coco-airline-dt-demo:pull_request'
);

GRANT ROLE AIRLINE_CI_RL TO USER SVC_GH_ACTIONS_CI;

-- Verify:
--   SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER SVC_GH_ACTIONS_CI;
