-- DBT-Actions/sql/data_gen/sp_gen_bookings.sql
-- Small booking batch (the LIVE feed). LIVE_WINDOW_DAYS > 0 limits it to flights departing in
-- the next N days (a contiguous flight_id range), like a real booking feed; 0 = any flight.
--
--   CALL airline_dbt_prod.data_gen.sp_gen_bookings(400, 7);

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.data_gen.sp_gen_bookings(
    n_rows NUMBER, live_window_days NUMBER DEFAULT 0)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  min_flight INTEGER;
  max_flight INTEGER;
  name_cnt   INTEGER;
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
  SELECT COUNT(*) INTO :name_cnt FROM data_gen.name_pool;

  INSERT INTO raw.bookings
    (booking_id, passenger_id, passenger_name, flight_id, fare_usd, seat_class, channel, booking_ts)
  WITH g AS (
    SELECT UNIFORM(:min_flight, :max_flight, RANDOM()) AS fid,
           UNIFORM(1, :name_cnt, RANDOM())             AS nid,
           UNIFORM(1, 100, RANDOM())                   AS cls_pick,
           UNIFORM(1, 100, RANDOM())                   AS chan_pick,
           UNIFORM(0, 60, RANDOM())                    AS lead_days
    FROM TABLE(GENERATOR(ROWCOUNT => :n_rows))
  )
  SELECT
    data_gen.booking_seq.NEXTVAL,
    UNIFORM(100000, 99999999, RANDOM()),
    np.full_name,
    f.flight_id,
    CASE WHEN g.cls_pick <= 70 THEN ROUND(80   + UNIFORM(0, 270,  RANDOM()), 2)
         WHEN g.cls_pick <= 85 THEN ROUND(200  + UNIFORM(0, 400,  RANDOM()), 2)
         WHEN g.cls_pick <= 97 THEN ROUND(600  + UNIFORM(0, 1400, RANDOM()), 2)
         ELSE                       ROUND(2000 + UNIFORM(0, 4000, RANDOM()), 2) END,
    CASE WHEN g.cls_pick <= 70 THEN 'ECONOMY'
         WHEN g.cls_pick <= 85 THEN 'PREMIUM'
         WHEN g.cls_pick <= 97 THEN 'BUSINESS'
         ELSE                       'FIRST' END,
    CASE WHEN g.chan_pick <= 45 THEN 'WEB'
         WHEN g.chan_pick <= 80 THEN 'MOBILE'
         WHEN g.chan_pick <= 93 THEN 'AGENT'
         ELSE                        'PARTNER' END,
    DATEADD('day', -g.lead_days, f.scheduled_dep_ts)::TIMESTAMP_NTZ
  FROM g
  JOIN raw.flights f          ON f.flight_id = g.fid
  JOIN data_gen.name_pool np  ON np.name_id = g.nid
  ORDER BY f.flight_id;

  RETURN 'BOOKINGS: inserted ' || :n_rows || ' rows';
END;
$$;
