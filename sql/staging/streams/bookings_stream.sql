-- staging/streams/bookings_stream.sql
-- Append-only stream on BOOKINGS. Used by the legacy pipeline ONLY as a change
-- trigger (SYSTEM$STREAM_HAS_DATA); the increment is consumed for bookkeeping and
-- then discarded in favor of a full recompute. Replaced entirely by the dynamic table.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE STREAM IF NOT EXISTS AIRLINE_PROD.STAGING.BOOKINGS_STREAM
  ON TABLE AIRLINE_PROD.STAGING.BOOKINGS
  APPEND_ONLY = TRUE
  COMMENT = 'Append-only change stream on STAGING.BOOKINGS';
