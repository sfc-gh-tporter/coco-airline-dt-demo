-- DBT-Actions/sql/data_gen/sp_gen_bookings_bulk.sql
-- Bulk bookings: each flight gets a booking count proportional to its seat capacity
-- (capacity * LOAD_TARGET * jitter 0.65..1.00), so load factors stay realistic across
-- regional jets and widebodies. Written in flight_id (= date) order for pruning.
--
--   CALL airline_dbt_prod.data_gen.sp_gen_bookings_bulk(0.85);

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.data_gen.sp_gen_bookings_bulk(load_target FLOAT)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  max_cap  INTEGER;
  name_cnt INTEGER;
BEGIN
  SELECT MAX(seat_capacity) INTO :max_cap  FROM raw.aircraft;
  SELECT COUNT(*)           INTO :name_cnt FROM data_gen.name_pool;

  INSERT INTO raw.bookings
    (booking_id, passenger_id, passenger_name, flight_id, fare_usd, seat_class, channel, booking_ts)
  WITH nums AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ8()) AS k FROM TABLE(GENERATOR(ROWCOUNT => :max_cap))
  ),
  exploded AS (
    SELECT f.flight_id, f.scheduled_dep_ts,
           ROUND(a.seat_capacity * :load_target * UNIFORM(0.65, 1.00, RANDOM())) AS tgt
    FROM raw.flights f
    JOIN raw.aircraft a ON a.aircraft_type = f.aircraft_type
  ),
  base AS (
    SELECT e.flight_id, e.scheduled_dep_ts,
           UNIFORM(1, :name_cnt, RANDOM()) AS nid,
           UNIFORM(1, 100, RANDOM())       AS cls_pick,
           UNIFORM(1, 100, RANDOM())       AS chan_pick,
           UNIFORM(0, 60, RANDOM())        AS lead_days
    FROM exploded e
    JOIN nums n ON n.k <= e.tgt
  )
  SELECT
    data_gen.booking_seq.NEXTVAL,
    UNIFORM(100000, 99999999, RANDOM()),
    np.full_name,
    b.flight_id,
    CASE WHEN b.cls_pick <= 70 THEN ROUND(80   + UNIFORM(0, 270,  RANDOM()), 2)
         WHEN b.cls_pick <= 85 THEN ROUND(200  + UNIFORM(0, 400,  RANDOM()), 2)
         WHEN b.cls_pick <= 97 THEN ROUND(600  + UNIFORM(0, 1400, RANDOM()), 2)
         ELSE                       ROUND(2000 + UNIFORM(0, 4000, RANDOM()), 2) END,
    CASE WHEN b.cls_pick <= 70 THEN 'ECONOMY'
         WHEN b.cls_pick <= 85 THEN 'PREMIUM'
         WHEN b.cls_pick <= 97 THEN 'BUSINESS'
         ELSE                       'FIRST' END,
    CASE WHEN b.chan_pick <= 45 THEN 'WEB'
         WHEN b.chan_pick <= 80 THEN 'MOBILE'
         WHEN b.chan_pick <= 93 THEN 'AGENT'
         ELSE                        'PARTNER' END,
    DATEADD('day', -b.lead_days, b.scheduled_dep_ts)::TIMESTAMP_NTZ
  FROM base b
  JOIN data_gen.name_pool np ON np.name_id = b.nid
  ORDER BY b.flight_id;

  RETURN 'BOOKINGS_BULK: capacity-proportional load ~' || :load_target;
END;
$$;
