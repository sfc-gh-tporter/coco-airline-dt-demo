-- DBT-Actions/sql/ops/deploy_log.sql
-- Audit trail for the dbt demo's prod deploys: one row per workflow step. Written by
-- scripts/ci/dbt_ci.py `record` (GitHub Actions, deploy identity).

USE ROLE airline_dbt_deploy_rl;

CREATE TABLE IF NOT EXISTS airline_dbt_prod.ops.deploy_log (
  deploy_id    VARCHAR        COMMENT 'GitHub run id and attempt',
  git_sha      VARCHAR        COMMENT 'Commit deployed',
  actor        VARCHAR        COMMENT 'GitHub user who triggered the deploy',
  step         VARCHAR        COMMENT 'DEPLOY_PROJECT, BUILD_SLICE or SMOKE_TEST',
  status       VARCHAR        COMMENT 'SUCCESS, FAILED or SKIPPED',
  models       VARCHAR        COMMENT 'Models in the changed slice (space separated)',
  query_tag    VARCHAR        COMMENT 'QUERY_TAG carried by every statement of the step',
  message      VARCHAR        COMMENT 'Result summary or error',
  started_at   TIMESTAMP_LTZ  COMMENT 'Step start',
  finished_at  TIMESTAMP_LTZ  COMMENT 'Step end'
) COMMENT = 'dbt DT demo: prod deploy audit log (one row per step)';
