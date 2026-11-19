-- staging/tables/flights.sql
-- Structured dimension. CREATE IF NOT EXISTS so deploys never wipe data.
-- CHANGE_TRACKING enabled (required for streams and for incremental dynamic tables).

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.STAGING.FLIGHTS (
  flight_id          NUMBER(38,0)   NOT NULL,
  flight_number      VARCHAR(8),
  origin             VARCHAR(3),
  dest               VARCHAR(3),
  route              VARCHAR(7),            -- origin || '-' || dest
  scheduled_dep_ts   TIMESTAMP_NTZ,
  aircraft_type      VARCHAR(8),
  seat_capacity      NUMBER(5,0)
)
COMMENT = 'Flight dimension: one row per scheduled flight';

ALTER TABLE AIRLINE_PROD.STAGING.FLIGHTS SET CHANGE_TRACKING = TRUE;
