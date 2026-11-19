{{ config(**dt_schedule('10 minutes')) }}

-- [6] Network scorecard: origin region x ISO week, rolled up from the route x day mart.
SELECT
    origin_region,
    DATE_TRUNC('week', flight_date)                              AS week_start,
    COUNT(*)                                                     AS route_days,
    SUM(flights)                                                 AS flights,
    SUM(cancelled_flights)                                       AS cancelled_flights,
    SUM(on_time_flights)                                         AS on_time_flights,
    SUM(delayed_flights)                                         AS delayed_flights,
    SUM(total_delay_minutes)                                     AS total_delay_minutes,
    SUM(controllable_disruptions)                                AS controllable_disruptions,
    SUM(uncontrollable_disruptions)                              AS uncontrollable_disruptions,
    SUM(controllable_delay_minutes)                              AS controllable_delay_minutes,
    SUM(seat_capacity)                                           AS seat_capacity,
    SUM(seats_sold)                                              AS seats_sold,
    SUM(revenue_usd)                                             AS revenue_usd,
    ROUND(SUM(seats_sold) / NULLIF(SUM(seat_capacity), 0), 4)    AS load_factor,
    ROUND(100 * SUM(on_time_flights) / NULLIF(SUM(flights), 0), 2) AS on_time_pct
FROM {{ ref('mart_route_daily') }}
GROUP BY origin_region, DATE_TRUNC('week', flight_date)
