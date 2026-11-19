{{ config(**dt_schedule('DOWNSTREAM')) }}

-- [2] Latest known status per flight: the most recent ops event wins.
SELECT
    flight_id,
    status          AS latest_status,
    gate            AS latest_gate,
    delay_minutes,
    delay_code      AS latest_delay_code,
    actual_dep_ts,
    actual_arr_ts,
    event_ts        AS status_as_of_ts
FROM {{ ref('stg_flight_status_events') }}
QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY event_ts DESC, event_id DESC) = 1
