-- staging/tables/bookings.sql
-- Structured fact (~1GB+). CREATE IF NOT EXISTS so deploys never wipe data.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.STAGING.BOOKINGS (
  booking_id      NUMBER(38,0)   NOT NULL,
  passenger_id    NUMBER(38,0),
  passenger_name  VARCHAR(120),
  flight_id       NUMBER(38,0),
  flight_date     DATE,
  fare_usd        NUMBER(10,2),
  seat_class      VARCHAR(12),            -- ECONOMY / PREMIUM / BUSINESS / FIRST
  channel         VARCHAR(16),            -- WEB / MOBILE / AGENT / PARTNER
  booking_ts      TIMESTAMP_NTZ
)
COMMENT = 'Booking fact: one row per seat sold';

ALTER TABLE AIRLINE_PROD.STAGING.BOOKINGS SET CHANGE_TRACKING = TRUE;
