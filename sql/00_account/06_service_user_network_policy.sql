-- 00_account/06_service_user_network_policy.sql
-- The account has a network policy that blocks GitHub Actions runners (their IPs are
-- dynamic). Standard CI/CD pattern: a user-level policy exemption on the service
-- account ONLY. The account-level policy stays intact for all human users.
--
-- Safe because SVC_GH_ACTIONS_AIRLINE is key-pair (JWT) only, has no password, and
-- holds a minimal scoped role (no ACCOUNTADMIN, no SELECT on sensitive data).
-- Requires ACCOUNTADMIN. One-time admin step (not part of CI/CD deploy).

USE ROLE ACCOUNTADMIN;

CREATE NETWORK POLICY IF NOT EXISTS GH_ACTIONS_AIRLINE_POLICY
  ALLOWED_IP_LIST = ('0.0.0.0/0')
  COMMENT = 'CI/CD service account only - GitHub Actions runners use dynamic IPs';

ALTER USER SVC_GH_ACTIONS_AIRLINE SET NETWORK_POLICY = GH_ACTIONS_AIRLINE_POLICY;

-- Verify:
--   DESC USER SVC_GH_ACTIONS_AIRLINE;   -- NETWORK_POLICY = GH_ACTIONS_AIRLINE_POLICY
