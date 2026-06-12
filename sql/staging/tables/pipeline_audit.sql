-- staging/tables/pipeline_audit.sql
-- Bookkeeping table the legacy rebuild proc writes to. Its only purpose is to
-- consume the append-only streams (advancing their offsets) so SYSTEM$STREAM_HAS_DATA
-- resets between task runs. This extra plumbing disappears with the dynamic table.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.STAGING.PIPELINE_AUDIT (
  run_ts          TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
  source_object   VARCHAR(64),
  rows_consumed   NUMBER(38,0)
)
COMMENT = 'Audit log: rows consumed from each stream per legacy task run';
