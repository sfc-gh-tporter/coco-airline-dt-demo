-- tests/gates/incremental_batch.sql
-- Localized change batch used by the CI "Incremental behavior" gate. CI rewrites
-- AIRLINE_PROD.<schema> to the PR's zero-copy clones (AIRLINE_CI.PR_<n>_<schema>) and
-- refuses to run if any prod reference survives - this file never touches prod.
--
-- Shape of a real booking feed: a few hundred new bookings/events on flights departing
-- in the next 7 days. flight_id is monotonic with departure date, so the batch lands in a
-- narrow id/date range and a correctly built incremental dynamic table rewrites only the
-- affected route x day groups.

INSERT INTO AIRLINE_PROD.STAGING.BOOKINGS
  (booking_id, passenger_id, passenger_name, flight_id, flight_date, fare_usd, seat_class, channel, booking_ts)
SELECT booking_id + 10000000000, passenger_id, passenger_name, flight_id, flight_date,
       fare_usd, seat_class, channel, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM AIRLINE_PROD.STAGING.BOOKINGS
WHERE flight_date >= CURRENT_DATE()
  AND flight_date <  DATEADD('day', 7, CURRENT_DATE())
LIMIT 400;

INSERT INTO AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS (event_id, flight_id, event_ts, payload)
SELECT e.event_id + 10000000000, e.flight_id, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, e.payload
FROM AIRLINE_PROD.STAGING.FLIGHT_STATUS_EVENTS e
WHERE e.flight_id BETWEEN
      (SELECT MIN(flight_id) FROM AIRLINE_PROD.STAGING.FLIGHTS WHERE scheduled_dep_ts >= CURRENT_DATE())
  AND (SELECT MAX(flight_id) FROM AIRLINE_PROD.STAGING.FLIGHTS
       WHERE scheduled_dep_ts < DATEADD('day', 7, CURRENT_DATE()))
LIMIT 250;
