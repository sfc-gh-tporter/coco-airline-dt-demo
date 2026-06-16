-- data_gen/sp_gen_bookings.sql
-- Bulk booking generator (pure SQL for speed). Appends N_ROWS bookings that
-- reference random real flights + Faker names. Uses BOOKING_SEQ so ids stay
-- unique across BULK and LIVE calls. Run SP_GEN_SEED first.
--
--   CALL AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS(30000000);

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS(N_ROWS NUMBER)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  max_flight INTEGER;
  name_cnt   INTEGER;
BEGIN
  SELECT MAX(flight_id) INTO :max_flight FROM STAGING.FLIGHTS;
  SELECT COUNT(*)       INTO :name_cnt   FROM DATA_GEN.NAME_POOL;

  INSERT INTO STAGING.BOOKINGS
    (booking_id, passenger_id, passenger_name, flight_id, flight_date,
     fare_usd, seat_class, channel, booking_ts)
  WITH g AS (
    SELECT
      UNIFORM(1, :max_flight, RANDOM()) AS fid,
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
  JOIN DATA_GEN.NAME_POOL np ON np.name_id = g.nid;

  RETURN 'BOOKINGS: inserted ' || :N_ROWS || ' rows';
END;
$$;
