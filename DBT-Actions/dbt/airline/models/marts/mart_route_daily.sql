{{ config(**dt_schedule('10 minutes')) }}

-- [5] Route x day KPIs. Stores additive sums and counts; rates are derived from them so the
--     weekly mart can roll this table up incrementally.
SELECT
    route,
    flight_date,
    origin_region,
    COUNT(*)                                                     AS flights,
    SUM(IFF(is_cancelled, 1, 0))                                 AS cancelled_flights,
    SUM(IFF(is_on_time, 1, 0))                                   AS on_time_flights,
    SUM(IFF(NOT is_on_time AND NOT is_cancelled, 1, 0))          AS delayed_flights,
    SUM(IFF(is_cancelled, 0, delay_minutes))                     AS total_delay_minutes,
    SUM(seat_capacity)                                           AS seat_capacity,
    SUM(seats_sold)                                              AS seats_sold,
    SUM(revenue_usd)                                             AS revenue_usd,
    ROUND(SUM(seats_sold) / NULLIF(SUM(seat_capacity), 0), 4)    AS load_factor,
    ROUND(100 * SUM(IFF(is_on_time, 1, 0)) / COUNT(*), 2)        AS on_time_pct
FROM {{ ref('int_flight_performance') }}
GROUP BY route, flight_date, origin_region
