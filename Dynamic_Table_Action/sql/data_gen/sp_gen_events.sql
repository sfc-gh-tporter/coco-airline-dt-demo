-- data_gen/sp_gen_events.sql
-- Bulk VARIANT event generator (pure SQL). Appends N_ROWS operational status
-- events as JSON, referencing random real flights. delay_minutes / status drive
-- the avg_delay_minutes and on_time_pct KPIs downstream. Run SP_GEN_SEED first.
--
-- LIVE_WINDOW_DAYS > 0 localizes events to flights departing in the next N days
-- (see SP_GEN_BOOKINGS). 0 = any flight in the schedule (BULK).
--
--   CALL AIRLINE_PROD.DATA_GEN.SP_GEN_EVENTS(8000000);     -- bulk
--   CALL AIRLINE_PROD.DATA_GEN.SP_GEN_EVENTS(250, 7);      -- live batch

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

DROP PROCEDURE IF EXISTS AIRLINE_PROD.DATA_GEN.SP_GEN_EVENTS(NUMBER);

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GEN_EVENTS(
    N_ROWS NUMBER, LIVE_WINDOW_DAYS NUMBER DEFAULT 0)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  min_flight INTEGER;
  max_flight INTEGER;
BEGIN
  IF (:LIVE_WINDOW_DAYS > 0) THEN
    SELECT MIN(flight_id), MAX(flight_id) INTO :min_flight, :max_flight
    FROM STAGING.FLIGHTS
    WHERE scheduled_dep_ts >= CURRENT_DATE()
      AND scheduled_dep_ts <  DATEADD('day', :LIVE_WINDOW_DAYS, CURRENT_DATE());
  END IF;
  IF (:min_flight IS NULL) THEN
    SELECT MIN(flight_id), MAX(flight_id) INTO :min_flight, :max_flight FROM STAGING.FLIGHTS;
  END IF;

  INSERT INTO STAGING.FLIGHT_STATUS_EVENTS
    (event_id, flight_id, event_ts, payload)
  WITH g AS (
    SELECT
      UNIFORM(:min_flight, :max_flight, RANDOM()) AS fid,
      UNIFORM(0, 100,         RANDOM()) AS st_pick,
      UNIFORM(0, 180,         RANDOM()) AS delay,
      UNIFORM(1, 35,          RANDOM()) AS gate_num,
      UNIFORM(-90, 90,        RANDOM()) AS ts_jitter
    FROM TABLE(GENERATOR(ROWCOUNT => :N_ROWS))
  )
  SELECT
    DATA_GEN.EVENT_SEQ.NEXTVAL,
    f.flight_id,
    DATEADD('minute', g.ts_jitter, f.scheduled_dep_ts)::TIMESTAMP_NTZ,
    OBJECT_CONSTRUCT(
      'status',
        CASE
          WHEN g.st_pick < 70 THEN 'ON_TIME'
          WHEN g.st_pick < 90 THEN 'DELAYED'
          WHEN g.st_pick < 97 THEN 'GATE_CHANGE'
          ELSE                     'CANCELLED'
        END,
      'gate', 'G' || g.gate_num::STRING,
      'delay_minutes', CASE WHEN g.st_pick < 70 THEN 0 ELSE g.delay END,
      'actual_dep_ts',
        DATEADD('minute', CASE WHEN g.st_pick < 70 THEN 0 ELSE g.delay END,
                f.scheduled_dep_ts)::STRING,
      'source', 'OPS'
    )
  FROM g
  JOIN STAGING.FLIGHTS f ON f.flight_id = g.fid
  ORDER BY g.fid;  -- write in flight_id(=date) order -> date-clustered for pruning

  RETURN 'FLIGHT_STATUS_EVENTS: inserted ' || :N_ROWS || ' rows';
END;
$$;
