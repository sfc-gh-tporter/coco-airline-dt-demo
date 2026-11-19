{{ config(**dt_schedule('DOWNSTREAM')) }}

-- [4] One row per flight: operations joined to commercial results.
SELECT
    o.flight_id,
    o.flight_number,
    o.route,
    o.origin,
    o.dest,
    o.origin_region,
    o.dest_region,
    o.is_hub_departure,
    o.flight_date,
    o.departure_bank,
    o.aircraft_type,
    o.aircraft_family,
    o.seat_capacity,
    o.flight_status,
    o.is_cancelled,
    o.delay_minutes,
    o.is_on_time,
    o.delay_bucket,
    o.delay_cause,
    o.is_controllable_delay,
    COALESCE(b.seats_sold, 0)            AS seats_sold,
    COALESCE(b.revenue_usd, 0)           AS revenue_usd,
    COALESCE(b.premium_seats_sold, 0)    AS premium_seats_sold,
    COALESCE(b.direct_channel_seats, 0)  AS direct_channel_seats
FROM {{ ref('int_flight_operations') }}        o
LEFT JOIN {{ ref('int_bookings_by_flight') }}  b ON b.flight_id = o.flight_id
