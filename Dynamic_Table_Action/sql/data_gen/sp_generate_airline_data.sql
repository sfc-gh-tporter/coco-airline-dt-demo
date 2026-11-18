-- data_gen/sp_generate_airline_data.sql
-- Orchestrator. One entry point with a SCALE knob and a MODE selector.
--
--   CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'SEED');  -- dims + flights
--   CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'BULK');  -- ~1GB+/table facts
--   CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'ALL');   -- full regen: truncate facts, SEED, BULK
--   CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'LIVE');  -- tiny batch on next-7-day flights
--
-- SCALE multiplies SEED/BULK volumes. LIVE ignores SCALE (always a small batch).
-- SCALE=1.0 ~= 2.2GB total; SCALE=5.0 ~= 10GB total (~3.2M flights, ~470M bookings, ~350M events).
-- Database-relative: nested CALLs are schema-qualified so this runs in prod OR a clone.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(SCALE FLOAT, MODE STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  msg          STRING DEFAULT '';
  n_names      INTEGER;
  n_flights    INTEGER;
  n_events     INTEGER;
  m            STRING DEFAULT UPPER(MODE);
BEGIN
  -- SCALE=1.0 yields ~1.1GB BOOKINGS (~94M rows) and ~1.1GB FLIGHT_STATUS_EVENTS
  -- (~69M rows) after compression. FLIGHTS stays a small dimension (~639k rows),
  -- sized so total seat capacity exceeds bookings -> realistic load factor.
  -- BULK booking volume is driven by SP_GEN_BOOKINGS_BULK (capacity-proportional),
  -- not by a fixed row count.
  n_names    := GREATEST(1000, (60000    * :SCALE)::INTEGER);
  n_flights  := GREATEST(1000, (650000   * :SCALE)::INTEGER);
  n_events   := GREATEST(1000, (70000000 * :SCALE)::INTEGER);

  IF (:m = 'ALL') THEN
    -- A full regen rebuilds the schedule, so the facts must start empty (BULK appends).
    TRUNCATE TABLE STAGING.BOOKINGS;
    TRUNCATE TABLE STAGING.FLIGHT_STATUS_EVENTS;
  END IF;

  IF (:m = 'SEED' OR :m = 'ALL') THEN
    CALL DATA_GEN.SP_GEN_SEED(:n_names, :n_flights);
    msg := msg || 'SEED ok; ';
  END IF;

  IF (:m = 'BULK' OR :m = 'ALL') THEN
    -- capacity-proportional bookings (realistic load); LOAD_TARGET ~ avg load factor
    CALL DATA_GEN.SP_GEN_BOOKINGS_BULK(0.85);
    CALL DATA_GEN.SP_GEN_EVENTS(:n_events);
    msg := msg || 'BULK ok (capacity-proportional bookings, ' || :n_events || ' events); ';
  END IF;

  IF (:m = 'LIVE') THEN
    -- small batch on flights departing in the next 7 days (a realistic booking feed)
    CALL DATA_GEN.SP_GEN_BOOKINGS(400, 7);
    CALL DATA_GEN.SP_GEN_EVENTS(250, 7);
    msg := msg || 'LIVE ok (400 bookings, 250 events, next 7 days); ';
  END IF;

  IF (:msg = '') THEN
    RETURN 'No-op: MODE must be one of SEED, BULK, ALL, LIVE (got ' || :MODE || ')';
  END IF;
  RETURN :msg;
END;
$$;
