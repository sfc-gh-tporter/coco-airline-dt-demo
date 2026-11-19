-- curated/tables/route_daily_performance.sql
-- Curated KPI mart: one row per route per day. This is the LEGACY target that the
-- full-recompute task overwrites every run. CREATE IF NOT EXISTS defines the schema
-- contract; the rebuild proc fills it with INSERT OVERWRITE.

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE TABLE IF NOT EXISTS AIRLINE_PROD.CURATED.ROUTE_DAILY_PERFORMANCE (
  route               VARCHAR(7),
  flight_date         DATE,
  seats_sold          NUMBER(38,0),
  revenue_usd         NUMBER(18,2),
  seat_capacity       NUMBER(38,0),
  load_factor         NUMBER(9,4),       -- seats_sold / seat_capacity
  avg_delay_minutes   NUMBER(9,2),
  on_time_pct         NUMBER(6,2)        -- % of flights with delay <= 15 min
)
CLUSTER BY (flight_date)
COMMENT = 'Route x day performance KPI (legacy full-recompute target)';
