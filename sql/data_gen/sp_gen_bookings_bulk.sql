-- data_gen/sp_gen_bookings_bulk.sql
-- Realistic bulk booking generator: assigns each flight a booking count
-- PROPORTIONAL to its seat capacity, so load_factor stays realistic
-- (~LOAD_TARGET, jittered) across both regional jets and widebodies - no
-- overbooked-looking rows. Used by the BULK path. For tiny live batches use
-- SP_GEN_BOOKINGS(N_ROWS) instead.
--
--   CALL AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS_BULK(0.85);  -- ~0.55-0.85 load

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GEN_BOOKINGS_BULK(LOAD_TARGET FLOAT)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  max_cap  INTEGER;
  name_cnt INTEGER;
BEGIN
  SELECT MAX(seat_capacity) INTO :max_cap  FROM AIRLINE_PROD.STAGING.FLIGHTS;
  SELECT COUNT(*)           INTO :name_cnt FROM AIRLINE_PROD.DATA_GEN.NAME_POOL;

  INSERT INTO AIRLINE_PROD.STAGING.BOOKINGS
    (booking_id, passenger_id, passenger_name, flight_id, flight_date,
     fare_usd, seat_class, channel, booking_ts)
  WITH nums AS (
    -- 1 .. max_capacity; used to explode each flight into per-seat rows
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ8()) AS k
    FROM TABLE(GENERATOR(ROWCOUNT => :max_cap))
  ),
  exploded AS (
    SELECT
      f.flight_id,
      f.scheduled_dep_ts,
      -- per-flight seats sold = capacity * load_target * jitter(0.65..1.00)
      ROUND(f.seat_capacity * :LOAD_TARGET * UNIFORM(0.65, 1.00, RANDOM())) AS tgt
    FROM AIRLINE_PROD.STAGING.FLIGHTS f
  ),
  base AS (
    SELECT
      e.flight_id,
      e.scheduled_dep_ts,
      UNIFORM(1, :name_cnt, RANDOM()) AS nid,
      UNIFORM(1, 100,       RANDOM()) AS cls_pick,
      UNIFORM(1, 100,       RANDOM()) AS chan_pick,
      UNIFORM(0, 60,        RANDOM()) AS lead_days
    FROM exploded e
    JOIN nums n ON n.k <= e.tgt
  )
  SELECT
    AIRLINE_PROD.DATA_GEN.BOOKING_SEQ.NEXTVAL,
    UNIFORM(100000, 99999999, RANDOM()),
    np.full_name,
    b.flight_id,
    b.scheduled_dep_ts::DATE,
    CASE
      WHEN b.cls_pick <= 70 THEN ROUND(80   + UNIFORM(0, 270,  RANDOM()), 2)
      WHEN b.cls_pick <= 85 THEN ROUND(200  + UNIFORM(0, 400,  RANDOM()), 2)
      WHEN b.cls_pick <= 97 THEN ROUND(600  + UNIFORM(0, 1400, RANDOM()), 2)
      ELSE                       ROUND(2000 + UNIFORM(0, 4000, RANDOM()), 2)
    END,
    CASE
      WHEN b.cls_pick <= 70 THEN 'ECONOMY'
      WHEN b.cls_pick <= 85 THEN 'PREMIUM'
      WHEN b.cls_pick <= 97 THEN 'BUSINESS'
      ELSE                       'FIRST'
    END,
    CASE
      WHEN b.chan_pick <= 45 THEN 'WEB'
      WHEN b.chan_pick <= 80 THEN 'MOBILE'
      WHEN b.chan_pick <= 93 THEN 'AGENT'
      ELSE                        'PARTNER'
    END,
    DATEADD('day', -b.lead_days, b.scheduled_dep_ts)::TIMESTAMP_NTZ
  FROM base b
  JOIN AIRLINE_PROD.DATA_GEN.NAME_POOL np ON np.name_id = b.nid;

  RETURN 'BOOKINGS_BULK: capacity-proportional load ~' || :LOAD_TARGET;
END;
$$;
