-- DBT-Actions/sql/data_gen/sp_generate_airline_data.sql
-- Orchestrator. Schema-relative calls, so it works in prod or in a clone (USE DATABASE first).
--
--   SCALE = 1.0  ->  ~650k flights, ~94M bookings, ~70M events (~2 GB)
--   MODE:
--     SEED  reference data + schedule (truncates flights; leaves facts)
--     BULK  capacity-proportional bookings + events (appends)
--     ALL   truncate facts, then SEED + BULK
--     LIVE  ~400 bookings + ~250 events on flights departing in the next 7 days (SCALE ignored)
--
--   USE DATABASE airline_dbt_prod;
--   CALL data_gen.sp_generate_airline_data(1.0, 'ALL');
--   CALL data_gen.sp_generate_airline_data(1.0, 'LIVE');

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.data_gen.sp_generate_airline_data(scale FLOAT, mode STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  m          STRING  DEFAULT UPPER(:mode);
  n_names    INTEGER DEFAULT GREATEST(1000, (60000    * :scale)::INTEGER);
  n_flights  INTEGER DEFAULT GREATEST(1000, (650000   * :scale)::INTEGER);
  n_events   INTEGER DEFAULT GREATEST(1000, (70000000 * :scale)::INTEGER);
  msg        STRING  DEFAULT '';
  r          STRING;
BEGIN
  IF (:m = 'ALL') THEN
    TRUNCATE TABLE raw.bookings;
    TRUNCATE TABLE raw.flight_status_events;
  END IF;
  IF (:m = 'SEED' OR :m = 'ALL') THEN
    CALL data_gen.sp_gen_seed(:n_names, :n_flights) INTO :r;
    msg := msg || r || ' | ';
  END IF;
  IF (:m = 'BULK' OR :m = 'ALL') THEN
    CALL data_gen.sp_gen_bookings_bulk(0.85) INTO :r;
    msg := msg || r || ' | ';
    CALL data_gen.sp_gen_events(:n_events) INTO :r;
    msg := msg || r;
  END IF;
  IF (:m = 'LIVE') THEN
    CALL data_gen.sp_gen_bookings(400, 7) INTO :r;
    msg := r || ' | ';
    CALL data_gen.sp_gen_events(250, 7) INTO :r;
    msg := msg || r;
  END IF;
  IF (:msg = '') THEN
    RETURN 'No-op: MODE must be one of SEED, BULK, ALL, LIVE (got ' || :mode || ')';
  END IF;
  RETURN :msg;
END;
$$;
