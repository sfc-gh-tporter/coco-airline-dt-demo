-- 00_account/04_schemas.sql
-- Schemas created AS the CI/CD role so the role owns them (and all objects in them).

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE SCHEMA IF NOT EXISTS AIRLINE_PROD.STAGING
  COMMENT = 'Raw landing tables + append-only streams (1GB+/table, generated in Snowflake)';

CREATE SCHEMA IF NOT EXISTS AIRLINE_PROD.CURATED
  COMMENT = 'Curated route x day KPI mart (legacy target table + the new dynamic table)';

CREATE SCHEMA IF NOT EXISTS AIRLINE_PROD.DATA_GEN
  COMMENT = 'Stored procedures that generate realistic airline data in Snowflake';

CREATE SCHEMA IF NOT EXISTS AIRLINE_PROD.OPS
  COMMENT = 'Operational metadata: production deploy audit log';

-- Remove the default PUBLIC schema to keep the database tidy.
DROP SCHEMA IF EXISTS AIRLINE_PROD.PUBLIC;
