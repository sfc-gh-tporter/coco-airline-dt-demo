-- DBT-Actions/sql/data_gen/sp_gen_events.sql
-- Ops feed: VARIANT status events for random real flights. Payload keys:
--   status         ON_TIME 70% | DELAYED 20% | GATE_CHANGE 7% | CANCELLED 3%
--   delay_minutes  0 when ON_TIME / GATE_CHANGE, else 5..180
--   delay_code     on DELAYED and CANCELLED only:
--                  WX 25% | ATC 20% | MX 20% | CREW 15% | PAX 10% | LATE_AIRCRAFT 10%
--   gate, actual_dep_ts, actual_arr_ts, source
-- LIVE_WINDOW_DAYS > 0 limits events to flights departing in the next N days; 0 = any flight.
--
--   CALL airline_dbt_prod.data_gen.sp_gen_events(70000000);   -- bulk
--   CALL airline_dbt_prod.data_gen.sp_gen_events(250, 7);     -- live batch

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.data_gen.sp_gen_events(
    n_rows NUMBER, live_window_days NUMBER DEFAULT 0)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  min_flight INTEGER;
  max_flight INTEGER;
BEGIN
  IF (:live_window_days > 0) THEN
    SELECT MIN(flight_id), MAX(flight_id) INTO :min_flight, :max_flight
    FROM raw.flights
    WHERE scheduled_dep_ts >= CURRENT_DATE()
      AND scheduled_dep_ts <  DATEADD('day', :live_window_days, CURRENT_DATE());
  END IF;
  IF (:min_flight IS NULL) THEN
    SELECT MIN(flight_id), MAX(flight_id) INTO :min_flight, :max_flight FROM raw.flights;
  END IF;

  INSERT INTO raw.flight_status_events (event_id, flight_id, event_ts, payload)
  WITH g AS (
    SELECT UNIFORM(:min_flight, :max_flight, RANDOM()) AS fid,
           UNIFORM(0, 99, RANDOM())                    AS st_pick,
           UNIFORM(0, 99, RANDOM())                    AS code_pick,
           UNIFORM(5, 180, RANDOM())                   AS delay,
           UNIFORM(1, 35, RANDOM())                    AS gate_num,
           UNIFORM(-90, 90, RANDOM())                  AS ts_jitter
    FROM TABLE(GENERATOR(ROWCOUNT => :n_rows))
  ),
  s AS (
    SELECT g.*,
           CASE WHEN st_pick < 70 THEN 'ON_TIME'
                WHEN st_pick < 90 THEN 'DELAYED'
                WHEN st_pick < 97 THEN 'GATE_CHANGE'
                ELSE                   'CANCELLED' END AS status
    FROM g
  )
  SELECT
    data_gen.event_seq.NEXTVAL,
    f.flight_id,
    DATEADD('minute', s.ts_jitter, f.scheduled_dep_ts)::TIMESTAMP_NTZ,
    OBJECT_CONSTRUCT_KEEP_NULL(
      'status',        s.status,
      'gate',          'G' || s.gate_num::STRING,
      'delay_minutes', IFF(s.status IN ('DELAYED', 'CANCELLED'), s.delay, 0),
      'delay_code',    IFF(s.status IN ('DELAYED', 'CANCELLED'),
                           CASE WHEN s.code_pick < 25 THEN 'WX'
                                WHEN s.code_pick < 45 THEN 'ATC'
                                WHEN s.code_pick < 65 THEN 'MX'
                                WHEN s.code_pick < 80 THEN 'CREW'
                                WHEN s.code_pick < 90 THEN 'PAX'
                                ELSE                      'LATE_AIRCRAFT' END,
                           NULL),
      'actual_dep_ts', IFF(s.status = 'CANCELLED', NULL,
                           DATEADD('minute', IFF(s.status = 'DELAYED', s.delay, 0), f.scheduled_dep_ts)::STRING),
      'actual_arr_ts', IFF(s.status = 'CANCELLED', NULL,
                           DATEADD('minute', IFF(s.status = 'DELAYED', s.delay, 0), f.scheduled_arr_ts)::STRING),
      'source',        'OPS'
    )
  FROM s
  JOIN raw.flights f ON f.flight_id = s.fid
  ORDER BY s.fid;

  RETURN 'FLIGHT_STATUS_EVENTS: inserted ' || :n_rows || ' rows';
END;
$$;
