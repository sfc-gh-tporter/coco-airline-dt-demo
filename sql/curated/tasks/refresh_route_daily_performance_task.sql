-- curated/tasks/refresh_route_daily_performance_task.sql
-- Legacy scheduler: every 5 minutes, IF any stream has data, run the full
-- recompute. Created SUSPENDED; the presenter resumes it during the walkthrough.
-- This task + the proc + the streams + the audit table are all replaced by the
-- single incremental Dynamic Table.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK
  WAREHOUSE = AIRLINE_DEMO_WH
  SCHEDULE  = '5 MINUTE'
  COMMENT   = 'Legacy: gated full recompute of ROUTE_DAILY_PERFORMANCE'
  WHEN
    SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.BOOKINGS_STREAM')
    OR SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS_STREAM')
    OR SYSTEM$STREAM_HAS_DATA('AIRLINE_PROD.STAGING.FLIGHTS_STREAM')
AS
  CALL AIRLINE_PROD.CURATED.SP_REBUILD_ROUTE_DAILY_PERFORMANCE();

-- Task is created SUSPENDED by default. Resume during the demo with:
--   ALTER TASK AIRLINE_PROD.CURATED.REFRESH_ROUTE_DAILY_PERFORMANCE_TASK RESUME;
