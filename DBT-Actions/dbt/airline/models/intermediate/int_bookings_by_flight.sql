{{ config(**dt_schedule('DOWNSTREAM')) }}

-- [b] Bookings rolled up to one row per flight (~94M rows in, one row per flight out).
SELECT
    flight_id,
    COUNT(*)                                     AS seats_sold,
    SUM(fare_usd)                                AS revenue_usd,
    SUM(IFF(seat_class = 'ECONOMY', 0, 1))       AS premium_seats_sold,
    SUM(IFF(channel IN ('WEB', 'MOBILE'), 1, 0)) AS direct_channel_seats
FROM {{ source('raw', 'bookings') }}
GROUP BY flight_id
