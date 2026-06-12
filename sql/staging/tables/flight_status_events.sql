-- staging/tables/flight_status_events.sql
-- Semi-structured VARIANT table (~1GB+). One row per operational status event.
-- payload example:
--   { "status":"DEPARTED", "gate":"B12", "delay_minutes":23,
--     "actual_dep_ts":"2026-03-01T14:23:00", "source":"OPS" }

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS (
  event_id    NUMBER(38,0)   NOT NULL,
  flight_id   NUMBER(38,0),
  event_ts    TIMESTAMP_NTZ,
  payload     VARIANT
)
COMMENT = 'Operational flight status events as JSON (gate changes, delays, dep/arr actuals)';

ALTER TABLE AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS SET CHANGE_TRACKING = TRUE;
