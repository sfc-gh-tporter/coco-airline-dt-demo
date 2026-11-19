{{ config(**dt_schedule('DOWNSTREAM')) }}

-- [3] Operational view of each flight: schedule + network + fleet + latest status.
--     The business rules for on-time / cancelled / delay buckets live here, so every mart
--     downstream reports them the same way.
SELECT
    f.flight_id,
    f.flight_number,
    f.origin || '-' || f.dest                           AS route,
    f.origin,
    f.dest,
    o.region                                            AS origin_region,
    d.region                                            AS dest_region,
    o.is_hub                                            AS is_hub_departure,
    f.scheduled_dep_ts::DATE                            AS flight_date,
    CASE
        WHEN HOUR(f.scheduled_dep_ts) BETWEEN 5  AND 10 THEN 'MORNING'
        WHEN HOUR(f.scheduled_dep_ts) BETWEEN 11 AND 16 THEN 'MIDDAY'
        WHEN HOUR(f.scheduled_dep_ts) BETWEEN 17 AND 21 THEN 'EVENING'
        ELSE 'NIGHT'
    END                                                 AS departure_bank,
    f.aircraft_type,
    a.family                                            AS aircraft_family,
    a.seat_capacity,
    COALESCE(s.latest_status, 'SCHEDULED')              AS flight_status,
    COALESCE(s.latest_status = 'CANCELLED', FALSE)      AS is_cancelled,
    COALESCE(s.delay_minutes, 0)                        AS delay_minutes,
    COALESCE(s.latest_status <> 'CANCELLED' AND s.delay_minutes <= 15, TRUE) AS is_on_time,
    CASE
        WHEN s.latest_status = 'CANCELLED'   THEN 'CANCELLED'
        WHEN COALESCE(s.delay_minutes, 0) <= 15 THEN 'ON_TIME'
        WHEN s.delay_minutes <= 60           THEN 'DELAY_16_60'
        WHEN s.delay_minutes <= 120          THEN 'DELAY_61_120'
        ELSE 'DELAY_120_PLUS'
    END                                                 AS delay_bucket
FROM {{ source('raw', 'flights') }}       f
JOIN {{ source('raw', 'airports') }}      o ON o.iata = f.origin
JOIN {{ source('raw', 'airports') }}      d ON d.iata = f.dest
JOIN {{ source('raw', 'aircraft') }}      a ON a.aircraft_type = f.aircraft_type
LEFT JOIN {{ ref('int_flight_status') }}  s ON s.flight_id = f.flight_id
