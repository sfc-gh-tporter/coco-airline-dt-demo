-- DBT-Actions/sql/raw/tables.sql
-- Raw airline data that the dbt DAG reads. One-time bootstrap (the generator fills them).
-- CHANGE_TRACKING = TRUE on every table: dynamic tables refresh incrementally from these,
-- and a CREATE OR REPLACE upstream would otherwise break downstream change tracking.

USE ROLE airline_dbt_deploy_rl;

CREATE TABLE IF NOT EXISTS airline_dbt_prod.raw.airports (
  iata          VARCHAR(3)   NOT NULL COMMENT 'IATA airport code',
  airport_name  VARCHAR(80)           COMMENT 'Airport name',
  city          VARCHAR(60)           COMMENT 'City served',
  country       VARCHAR(2)            COMMENT 'ISO country code',
  region        VARCHAR(20)           COMMENT 'Network region (US_EAST, US_CENTRAL, US_WEST, LATAM, EUROPE, MIDDLE_EAST, ASIA_PACIFIC)',
  is_hub        BOOLEAN               COMMENT 'TRUE for the airline''s hub airports',
  timezone      VARCHAR(40)           COMMENT 'IANA time zone'
) CHANGE_TRACKING = TRUE COMMENT = 'Airport reference data: one row per airport';

CREATE TABLE IF NOT EXISTS airline_dbt_prod.raw.aircraft (
  aircraft_type  VARCHAR(8)  NOT NULL COMMENT 'ICAO aircraft type code',
  family         VARCHAR(12)          COMMENT 'REGIONAL, NARROWBODY or WIDEBODY',
  seat_capacity  NUMBER(5,0)          COMMENT 'Seats in the airline''s configuration'
) CHANGE_TRACKING = TRUE COMMENT = 'Fleet reference data: one row per aircraft type';

CREATE TABLE IF NOT EXISTS airline_dbt_prod.raw.flights (
  flight_id         NUMBER(38,0) NOT NULL COMMENT 'Flight key (monotonic with scheduled departure)',
  flight_number     VARCHAR(8)            COMMENT 'Marketing flight number',
  origin            VARCHAR(3)            COMMENT 'Origin IATA code',
  dest              VARCHAR(3)            COMMENT 'Destination IATA code',
  scheduled_dep_ts  TIMESTAMP_NTZ         COMMENT 'Scheduled departure (UTC)',
  scheduled_arr_ts  TIMESTAMP_NTZ         COMMENT 'Scheduled arrival (UTC)',
  aircraft_type     VARCHAR(8)            COMMENT 'Planned aircraft type'
) CHANGE_TRACKING = TRUE COMMENT = 'Published schedule: one row per scheduled flight';

CREATE TABLE IF NOT EXISTS airline_dbt_prod.raw.bookings (
  booking_id      NUMBER(38,0) NOT NULL COMMENT 'Booking key',
  passenger_id    NUMBER(38,0)          COMMENT 'Passenger key',
  passenger_name  VARCHAR(120)          COMMENT 'Passenger full name (synthetic)',
  flight_id       NUMBER(38,0)          COMMENT 'Booked flight',
  fare_usd        NUMBER(10,2)          COMMENT 'Fare paid (USD)',
  seat_class      VARCHAR(12)           COMMENT 'ECONOMY, PREMIUM, BUSINESS or FIRST',
  channel         VARCHAR(16)           COMMENT 'WEB, MOBILE, AGENT or PARTNER',
  booking_ts      TIMESTAMP_NTZ         COMMENT 'When the booking was made'
) CHANGE_TRACKING = TRUE COMMENT = 'Booking fact: one row per seat sold';

CREATE TABLE IF NOT EXISTS airline_dbt_prod.raw.flight_status_events (
  event_id   NUMBER(38,0) NOT NULL COMMENT 'Event key (monotonic with load order)',
  flight_id  NUMBER(38,0)          COMMENT 'Flight the event is about',
  event_ts   TIMESTAMP_NTZ         COMMENT 'When ops reported the event',
  payload    VARIANT               COMMENT 'Ops feed JSON: status, gate, delay_minutes, delay_code, actual_dep_ts, actual_arr_ts, source'
) CHANGE_TRACKING = TRUE COMMENT = 'Operational flight status events as JSON (ops feed)';
