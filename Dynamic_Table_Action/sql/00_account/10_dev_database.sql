-- 00_account/10_dev_database.sql
-- Developer sandboxes. One database, one schema per developer (e.g. AIRLINE_DEV.TPORTER),
-- holding zero-copy clones of only the prod tables a change needs. Developers build and
-- test there, then ship the change through a pull request. SYSADMIN owns it; it reads
-- prod through AIRLINE_CI_RL (SELECT only), so a sandbox can never write to prod.
--
-- One-time bootstrap; NOT part of the CI/CD deploy.

USE ROLE SYSADMIN;

-- No Time Travel: sandbox clones are throwaway.
CREATE DATABASE IF NOT EXISTS AIRLINE_DEV
  DATA_RETENTION_TIME_IN_DAYS = 0
  COMMENT = 'Developer sandboxes: one schema per developer with zero-copy clones of prod tables.';
DROP SCHEMA IF EXISTS AIRLINE_DEV.PUBLIC;

-- Each developer creates their own schema by hand, for example:
--   CREATE SCHEMA IF NOT EXISTS airline_dev.tporter;
--   CREATE OR REPLACE TABLE airline_dev.tporter.bookings CLONE airline_prod.staging.bookings;
