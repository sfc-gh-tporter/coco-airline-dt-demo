-- DBT-Actions/sql/00_account/01_roles.sql
-- Roles for the dbt dynamic-table DAG demo. One-time bootstrap; never deployed by CI.
--
--   airline_dbt_deploy_rl  owns AIRLINE_DBT_PROD and everything dbt builds in prod.
--   airline_dbt_ci_rl      read-only on prod; owns only the per-PR clone databases.
--
-- The CI role is granted TO the deploy role (not the other way round). The clone procedure
-- runs with the deploy role's rights and must hand ownership of each PR clone to the CI role;
-- Snowflake only transfers ownership to a role that is active in the session, so the owner
-- role has to inherit the CI role. This gives prod the CI role's privileges, never the reverse.

USE ROLE securityadmin;

CREATE ROLE IF NOT EXISTS airline_dbt_deploy_rl COMMENT = 'dbt DT demo: prod owner / deploy role';
CREATE ROLE IF NOT EXISTS airline_dbt_ci_rl     COMMENT = 'dbt DT demo: CI role (read prod, owns PR clones)';

GRANT ROLE airline_dbt_ci_rl     TO ROLE airline_dbt_deploy_rl;
GRANT ROLE airline_dbt_deploy_rl TO ROLE sysadmin;
GRANT ROLE airline_dbt_deploy_rl TO USER tporter;
GRANT ROLE airline_dbt_ci_rl     TO USER tporter;

USE ROLE accountadmin;
GRANT CREATE DATABASE ON ACCOUNT        TO ROLE airline_dbt_deploy_rl;   -- prod DB + PR clones (via proc)
GRANT EXECUTE TASK ON ACCOUNT           TO ROLE airline_dbt_deploy_rl;   -- daily state-keeper task
GRANT EXECUTE MANAGED TASK ON ACCOUNT   TO ROLE airline_dbt_deploy_rl;
