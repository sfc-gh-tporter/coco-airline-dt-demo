-- 00_account/06_service_user_network_policy.sql
-- The account network policy blocks GitHub-hosted runners (their IPs are dynamic).
-- Standard CI/CD pattern: a user-level policy on the two GitHub Actions service users
-- ONLY. The account-level policy stays intact for every human user.
--
-- Safe because both users are OIDC-only (no password, no key), each trusts a single
-- GitHub subject for this repo, and each holds one scoped role.
-- Requires ACCOUNTADMIN. One-time bootstrap (not part of the CI/CD deploy).

USE ROLE ACCOUNTADMIN;

CREATE NETWORK POLICY IF NOT EXISTS GH_ACTIONS_AIRLINE_POLICY
  ALLOWED_IP_LIST = ('0.0.0.0/0')
  COMMENT = 'GitHub Actions service users only - hosted runners use dynamic IPs';

ALTER USER SVC_GH_ACTIONS_AIRLINE SET NETWORK_POLICY = GH_ACTIONS_AIRLINE_POLICY;
ALTER USER SVC_GH_ACTIONS_CI      SET NETWORK_POLICY = GH_ACTIONS_AIRLINE_POLICY;

-- Verify:
--   DESC USER SVC_GH_ACTIONS_CI;   -- NETWORK_POLICY = GH_ACTIONS_AIRLINE_POLICY
