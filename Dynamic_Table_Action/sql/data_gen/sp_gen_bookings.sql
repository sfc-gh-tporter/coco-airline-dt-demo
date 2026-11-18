-- data_gen/sp_gen_bookings.sql
-- Small-batch booking generator (pure SQL). Appends N_ROWS bookings that
-- reference real flights + Faker names. Uses BOOKING_SEQ so ids stay unique
-- across BULK and LIVE calls. Run SP_GEN_SEED first.
--
-- LIVE_WINDOW_DAYS > 0 localizes the batch to flights departing in the next N days
-- (flight_id is monotonic with date, so this is a contiguous id range). That is what
-- a real booking feed looks like, and it lets incremental refreshes prune by date.
-- 0 = any flight in the schedule.
--
--   CALL AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS(400, 7);

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

DROP PROCEDURE IF EXISTS AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS(NUMBER);

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS(
    N_ROWS NUMBER, LIVE_WINDOW_DAYS NUMBER DEFAULT 0)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  min_flight INTEGER;
  max_flight INTEGER;
  name_cnt   INTEGER;
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
  SELECT COUNT(*) INTO :name_cnt FROM DATA_GEN.NAME_POOL;

  INSERT INTO STAGING.BOOKINGS
    (booking_id, passenger_id, passenger_name, flight_id, flight_date,
     fare_usd, seat_class, channel, booking_ts)
  WITH g AS (
    SELECT
      UNIFORM(:min_flight, :max_flight, RANDOM()) AS fid,
      UNIFORM(1, :name_cnt,   RANDOM()) AS nid,
      UNIFORM(1, 100,         RANDOM()) AS cls_pick,
      UNIFORM(1, 100,         RANDOM()) AS chan_pick,
      UNIFORM(0, 60,          RANDOM()) AS lead_days,
      RANDOM()                          AS r_fare
    FROM TABLE(GENERATOR(ROWCOUNT => :N_ROWS))
  )
  SELECT
    DATA_GEN.BOOKING_SEQ.NEXTVAL,
    UNIFORM(100000, 99999999, RANDOM()),
    np.full_name,
    f.flight_id,
    f.scheduled_dep_ts::DATE,
    CASE
      WHEN g.cls_pick <= 70 THEN ROUND(80  + UNIFORM(0, 270,  RANDOM()), 2)
      WHEN g.cls_pick <= 85 THEN ROUND(200 + UNIFORM(0, 400,  RANDOM()), 2)
      WHEN g.cls_pick <= 97 THEN ROUND(600 + UNIFORM(0, 1400, RANDOM()), 2)
      ELSE                       ROUND(2000 + UNIFORM(0, 4000, RANDOM()), 2)
    END,
    CASE
      WHEN g.cls_pick <= 70 THEN 'ECONOMY'
      WHEN g.cls_pick <= 85 THEN 'PREMIUM'
      WHEN g.cls_pick <= 97 THEN 'BUSINESS'
      ELSE                       'FIRST'
    END,
    CASE
      WHEN g.chan_pick <= 45 THEN 'WEB'
      WHEN g.chan_pick <= 80 THEN 'MOBILE'
      WHEN g.chan_pick <= 93 THEN 'AGENT'
      ELSE                        'PARTNER'
    END,
    DATEADD('day', -g.lead_days, f.scheduled_dep_ts)::TIMESTAMP_NTZ
  FROM g
  JOIN STAGING.FLIGHTS   f  ON f.flight_id = g.fid
  JOIN DATA_GEN.NAME_POOL np ON np.name_id = g.nid
  ORDER BY f.flight_id;

  RETURN 'BOOKINGS: inserted ' || :N_ROWS || ' rows';
END;
$$;
