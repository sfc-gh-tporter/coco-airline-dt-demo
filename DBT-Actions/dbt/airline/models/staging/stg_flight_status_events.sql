{{ config(**dt_schedule('DOWNSTREAM')) }}

-- [1] Ops feed, typed: one row per status event with the JSON payload parsed into columns.
--     Largest model in the DAG (~70M rows); never rebuilt by changes further downstream.
SELECT
    event_id,
    flight_id,
    event_ts,
    payload:status::VARCHAR               AS status,
    payload:gate::VARCHAR                 AS gate,
    payload:delay_minutes::NUMBER(5,0)    AS delay_minutes,
    payload:delay_code::VARCHAR           AS delay_code,
    payload:actual_dep_ts::TIMESTAMP_NTZ  AS actual_dep_ts,
    payload:actual_arr_ts::TIMESTAMP_NTZ  AS actual_arr_ts,
    payload:source::VARCHAR               AS source
FROM {{ source('raw', 'flight_status_events') }}
