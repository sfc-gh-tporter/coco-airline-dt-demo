-- ops/tables/deploy_log.sql
-- Audit trail for production deploys: one row per SQL file applied by GitHub Actions.
-- Every deploy statement also carries QUERY_TAG = 'gh:prod:<sha>:<run_id>:<file>', so a
-- row here joins to the exact queries in QUERY_HISTORY. CREATE IF NOT EXISTS keeps history.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.OPS.DEPLOY_LOG (
  deploy_id     VARCHAR(64)    COMMENT 'GitHub run id + attempt that performed the deploy',
  git_sha       VARCHAR(40)    COMMENT 'Commit deployed',
  actor         VARCHAR(100)   COMMENT 'GitHub user who triggered the run (merger)',
  file_path     VARCHAR(500)   COMMENT 'Repo-relative SQL file applied',
  action        VARCHAR(20)    COMMENT 'DEPLOY, SMOKE_TEST, or ROLLBACK',
  status        VARCHAR(20)    COMMENT 'SUCCESS or FAILED',
  query_tag     VARCHAR(500)   COMMENT 'QUERY_TAG set on every statement of this step',
  message       VARCHAR(4000)  COMMENT 'Error text or summary',
  started_at    TIMESTAMP_LTZ  COMMENT 'Step start',
  finished_at   TIMESTAMP_LTZ  COMMENT 'Step end'
)
COMMENT = 'Production deploy audit log written by GitHub Actions (deploy.yml)';
