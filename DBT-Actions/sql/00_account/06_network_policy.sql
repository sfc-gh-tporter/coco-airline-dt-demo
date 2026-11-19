-- DBT-Actions/sql/00_account/06_network_policy.sql
-- The account enforces a VPN-only network policy, so the GitHub-hosted runners need a
-- user-level policy. Uses Snowflake's managed GitHub Actions rule instead of an open CIDR.
-- Applies to the two dbt demo service users only. Requires ACCOUNTADMIN.

USE ROLE accountadmin;

CREATE NETWORK POLICY IF NOT EXISTS airline_dbt_gh_actions_policy
  ALLOWED_NETWORK_RULE_LIST = ('SNOWFLAKE.NETWORK_SECURITY.GITHUBACTIONS_GLOBAL')
  COMMENT = 'dbt DT demo: GitHub-hosted runners only (Snowflake-managed rule)';

ALTER USER svc_gh_dbt_ci     SET NETWORK_POLICY = airline_dbt_gh_actions_policy;
ALTER USER svc_gh_dbt_deploy SET NETWORK_POLICY = airline_dbt_gh_actions_policy;
