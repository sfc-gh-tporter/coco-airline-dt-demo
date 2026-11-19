-- DBT-Actions/sql/00_account/03_database.sql
-- One database holds the raw data AND the whole dbt DAG, so a single zero-copy clone captures
-- base tables and dynamic tables together (the docs-recommended way to clone a pipeline).
--
--   raw           base tables (CHANGE_TRACKING = TRUE)       data_gen   generator procs
--   staging / intermediate / marts   dbt-built dynamic tables
--   dbt           dbt project objects                         ops        deploy log, CI clone proc

USE ROLE airline_dbt_deploy_rl;

CREATE DATABASE IF NOT EXISTS airline_dbt_prod
  COMMENT = 'dbt DT demo: raw data + dbt dynamic table DAG (prod)';

CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.raw          COMMENT = 'Raw airline data (base tables, change tracking on)';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.data_gen     COMMENT = 'Synthetic data generator procedures';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.staging      COMMENT = 'dbt: typed, parsed source models';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.intermediate COMMENT = 'dbt: per-flight business logic';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.marts        COMMENT = 'dbt: consumer-facing KPI marts';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.dbt          COMMENT = 'dbt project objects';
CREATE SCHEMA IF NOT EXISTS airline_dbt_prod.ops          COMMENT = 'Deploy log and CI helpers';
DROP SCHEMA IF EXISTS airline_dbt_prod.public;

-- CI reads prod (blast-radius state, parity reference) but never writes it.
GRANT USAGE ON DATABASE airline_dbt_prod                              TO ROLE airline_dbt_ci_rl;
GRANT USAGE ON ALL SCHEMAS IN DATABASE airline_dbt_prod               TO ROLE airline_dbt_ci_rl;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE airline_dbt_prod            TO ROLE airline_dbt_ci_rl;
GRANT SELECT ON ALL TABLES IN DATABASE airline_dbt_prod               TO ROLE airline_dbt_ci_rl;
GRANT SELECT ON FUTURE TABLES IN DATABASE airline_dbt_prod            TO ROLE airline_dbt_ci_rl;
GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE airline_dbt_prod       TO ROLE airline_dbt_ci_rl;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN DATABASE airline_dbt_prod    TO ROLE airline_dbt_ci_rl;
GRANT MONITOR ON FUTURE DBT PROJECTS IN SCHEMA airline_dbt_prod.dbt   TO ROLE airline_dbt_ci_rl;  -- state import
