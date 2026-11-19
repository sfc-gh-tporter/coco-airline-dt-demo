-- DBT-Actions/sql/data_gen/sp_gen_seed.sql
-- Reference data + published schedule. Passenger names come from Faker (Python); airports,
-- aircraft and flights are plain SQL inserts so the raw tables keep CHANGE_TRACKING (a pandas
-- overwrite would recreate them). Resolves objects in whatever database it runs in, so it
-- works in prod or in a clone.
--
--   USE DATABASE airline_dbt_prod;  CALL data_gen.sp_gen_seed(60000, 650000);
--      arg1 = passenger names in the pool   arg2 = flights in the schedule

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.data_gen.sp_gen_seed(name_count NUMBER, n_flights NUMBER)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'faker', 'pandas')
  HANDLER = 'run'
AS
$$
import pandas as pd
from faker import Faker

# iata, name, city, country, region, is_hub, timezone
AIRPORTS = [
    ("ATL", "Hartsfield-Jackson Atlanta", "Atlanta", "US", "US_EAST", True, "America/New_York"),
    ("JFK", "John F. Kennedy", "New York", "US", "US_EAST", True, "America/New_York"),
    ("ORD", "O'Hare", "Chicago", "US", "US_CENTRAL", True, "America/Chicago"),
    ("DFW", "Dallas/Fort Worth", "Dallas", "US", "US_CENTRAL", True, "America/Chicago"),
    ("DEN", "Denver", "Denver", "US", "US_WEST", True, "America/Denver"),
    ("LAX", "Los Angeles", "Los Angeles", "US", "US_WEST", True, "America/Los_Angeles"),
    ("BOS", "Logan", "Boston", "US", "US_EAST", False, "America/New_York"),
    ("EWR", "Newark Liberty", "Newark", "US", "US_EAST", False, "America/New_York"),
    ("LGA", "LaGuardia", "New York", "US", "US_EAST", False, "America/New_York"),
    ("PHL", "Philadelphia", "Philadelphia", "US", "US_EAST", False, "America/New_York"),
    ("DCA", "Reagan National", "Washington", "US", "US_EAST", False, "America/New_York"),
    ("IAD", "Dulles", "Washington", "US", "US_EAST", False, "America/New_York"),
    ("BWI", "Baltimore/Washington", "Baltimore", "US", "US_EAST", False, "America/New_York"),
    ("CLT", "Charlotte Douglas", "Charlotte", "US", "US_EAST", False, "America/New_York"),
    ("RDU", "Raleigh-Durham", "Raleigh", "US", "US_EAST", False, "America/New_York"),
    ("MCO", "Orlando", "Orlando", "US", "US_EAST", False, "America/New_York"),
    ("MIA", "Miami", "Miami", "US", "US_EAST", False, "America/New_York"),
    ("FLL", "Fort Lauderdale", "Fort Lauderdale", "US", "US_EAST", False, "America/New_York"),
    ("TPA", "Tampa", "Tampa", "US", "US_EAST", False, "America/New_York"),
    ("DTW", "Detroit Metro", "Detroit", "US", "US_CENTRAL", False, "America/Detroit"),
    ("MSP", "Minneapolis-St Paul", "Minneapolis", "US", "US_CENTRAL", False, "America/Chicago"),
    ("MDW", "Midway", "Chicago", "US", "US_CENTRAL", False, "America/Chicago"),
    ("STL", "St. Louis Lambert", "St. Louis", "US", "US_CENTRAL", False, "America/Chicago"),
    ("BNA", "Nashville", "Nashville", "US", "US_CENTRAL", False, "America/Chicago"),
    ("IAH", "George Bush Intercontinental", "Houston", "US", "US_CENTRAL", False, "America/Chicago"),
    ("HOU", "Hobby", "Houston", "US", "US_CENTRAL", False, "America/Chicago"),
    ("AUS", "Austin-Bergstrom", "Austin", "US", "US_CENTRAL", False, "America/Chicago"),
    ("DAL", "Dallas Love Field", "Dallas", "US", "US_CENTRAL", False, "America/Chicago"),
    ("MSY", "Louis Armstrong", "New Orleans", "US", "US_CENTRAL", False, "America/Chicago"),
    ("PHX", "Phoenix Sky Harbor", "Phoenix", "US", "US_WEST", False, "America/Phoenix"),
    ("LAS", "Harry Reid", "Las Vegas", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SLC", "Salt Lake City", "Salt Lake City", "US", "US_WEST", False, "America/Denver"),
    ("SFO", "San Francisco", "San Francisco", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SJC", "San Jose", "San Jose", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SMF", "Sacramento", "Sacramento", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SAN", "San Diego", "San Diego", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SNA", "John Wayne", "Santa Ana", "US", "US_WEST", False, "America/Los_Angeles"),
    ("SEA", "Seattle-Tacoma", "Seattle", "US", "US_WEST", False, "America/Los_Angeles"),
    ("PDX", "Portland", "Portland", "US", "US_WEST", False, "America/Los_Angeles"),
    ("HNL", "Daniel K. Inouye", "Honolulu", "US", "US_WEST", False, "Pacific/Honolulu"),
    ("YYZ", "Toronto Pearson", "Toronto", "CA", "US_EAST", False, "America/Toronto"),
    ("MEX", "Mexico City", "Mexico City", "MX", "LATAM", False, "America/Mexico_City"),
    ("CUN", "Cancun", "Cancun", "MX", "LATAM", False, "America/Cancun"),
    ("GRU", "Sao Paulo Guarulhos", "Sao Paulo", "BR", "LATAM", False, "America/Sao_Paulo"),
    ("BOG", "El Dorado", "Bogota", "CO", "LATAM", False, "America/Bogota"),
    ("LHR", "Heathrow", "London", "GB", "EUROPE", False, "Europe/London"),
    ("CDG", "Charles de Gaulle", "Paris", "FR", "EUROPE", False, "Europe/Paris"),
    ("AMS", "Schiphol", "Amsterdam", "NL", "EUROPE", False, "Europe/Amsterdam"),
    ("FRA", "Frankfurt", "Frankfurt", "DE", "EUROPE", False, "Europe/Berlin"),
    ("MUC", "Munich", "Munich", "DE", "EUROPE", False, "Europe/Berlin"),
    ("MAD", "Barajas", "Madrid", "ES", "EUROPE", False, "Europe/Madrid"),
    ("BCN", "El Prat", "Barcelona", "ES", "EUROPE", False, "Europe/Madrid"),
    ("FCO", "Fiumicino", "Rome", "IT", "EUROPE", False, "Europe/Rome"),
    ("DXB", "Dubai", "Dubai", "AE", "MIDDLE_EAST", False, "Asia/Dubai"),
    ("NRT", "Narita", "Tokyo", "JP", "ASIA_PACIFIC", False, "Asia/Tokyo"),
    ("HND", "Haneda", "Tokyo", "JP", "ASIA_PACIFIC", False, "Asia/Tokyo"),
    ("ICN", "Incheon", "Seoul", "KR", "ASIA_PACIFIC", False, "Asia/Seoul"),
    ("HKG", "Hong Kong", "Hong Kong", "HK", "ASIA_PACIFIC", False, "Asia/Hong_Kong"),
    ("SIN", "Changi", "Singapore", "SG", "ASIA_PACIFIC", False, "Asia/Singapore"),
    ("SYD", "Kingsford Smith", "Sydney", "AU", "ASIA_PACIFIC", False, "Australia/Sydney"),
]
# aircraft_type, family, seat_capacity
AIRCRAFT = [
    ("E175", "REGIONAL", 76), ("CRJ9", "REGIONAL", 90),
    ("A320", "NARROWBODY", 180), ("B738", "NARROWBODY", 189), ("B752", "NARROWBODY", 199),
    ("B739", "NARROWBODY", 201), ("A321", "NARROWBODY", 220),
    ("B788", "WIDEBODY", 242), ("A359", "WIDEBODY", 315), ("B77W", "WIDEBODY", 396),
]


def lit(v):
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def run(session, name_count, n_flights):
    name_count, n_flights = int(name_count), int(n_flights)
    db = session.get_current_database().strip('"')
    gen, raw = f"{db}.data_gen", f"{db}.raw"

    session.sql(f"CREATE SEQUENCE IF NOT EXISTS {gen}.booking_seq START = 1 INCREMENT = 1").collect()
    session.sql(f"CREATE SEQUENCE IF NOT EXISTS {gen}.event_seq   START = 1 INCREMENT = 1").collect()

    Faker.seed(42)
    fake = Faker()
    names = pd.DataFrame([(i + 1, fake.name()) for i in range(name_count)], columns=["NAME_ID", "FULL_NAME"])
    session.write_pandas(names, "NAME_POOL", database=db, schema="DATA_GEN",
                         auto_create_table=True, overwrite=True)

    session.sql(f"TRUNCATE TABLE {raw}.airports").collect()
    session.sql(f"INSERT INTO {raw}.airports (iata, airport_name, city, country, region, is_hub, timezone) VALUES "
                + ", ".join("(" + ", ".join(lit(v) for v in a) + ")" for a in AIRPORTS)).collect()
    session.sql(f"TRUNCATE TABLE {raw}.aircraft").collect()
    session.sql(f"INSERT INTO {raw}.aircraft (aircraft_type, family, seat_capacity) VALUES "
                + ", ".join("(" + ", ".join(lit(v) for v in a) + ")" for a in AIRCRAFT)).collect()

    # Schedule spans -270..+90 days around today. flight_id follows departure order and rows
    # are inserted sorted, so facts generated in flight_id order are date-clustered.
    # Hubs get ~3x the departures and arrivals of spoke airports.
    session.sql(f"TRUNCATE TABLE {raw}.flights").collect()
    w_total = sum(3 if a[5] else 1 for a in AIRPORTS)
    session.sql(f"""
        INSERT INTO {raw}.flights
          (flight_id, flight_number, origin, dest, scheduled_dep_ts, scheduled_arr_ts, aircraft_type)
        WITH ap AS (
          SELECT iata, SUM(IFF(is_hub, 3, 1)) OVER (ORDER BY iata) AS hi
          FROM {raw}.airports
        ),
        ap_rng AS (SELECT iata, hi - LAG(hi, 1, 0) OVER (ORDER BY hi) AS w, hi FROM ap),
        ac AS (SELECT aircraft_type, family, ROW_NUMBER() OVER (ORDER BY aircraft_type) AS rn
               FROM {raw}.aircraft),
        s AS (
          SELECT
            DATEADD('minute', UNIFORM(0, 1439, RANDOM()),
              DATEADD('day', UNIFORM(-270, 90, RANDOM()), DATE_TRUNC('day', CURRENT_TIMESTAMP())))::TIMESTAMP_NTZ AS sched,
            UNIFORM(1, {w_total}, RANDOM())       AS o_pick,
            UNIFORM(1, {w_total}, RANDOM())       AS d_pick,
            UNIFORM(1, {len(AIRCRAFT)}, RANDOM()) AS ac_pick
          FROM TABLE(GENERATOR(ROWCOUNT => {n_flights}))
        )
        SELECT
          ROW_NUMBER() OVER (ORDER BY s.sched)                                        AS flight_id,
          'XA' || LPAD(MOD(ROW_NUMBER() OVER (ORDER BY s.sched), 9000) + 100, 4, '0') AS flight_number,
          o.iata, d.iata, s.sched,
          DATEADD('minute', CASE ac.family WHEN 'REGIONAL' THEN UNIFORM(55, 150, RANDOM())
                                          WHEN 'NARROWBODY' THEN UNIFORM(75, 330, RANDOM())
                                          ELSE UNIFORM(300, 840, RANDOM()) END, s.sched)::TIMESTAMP_NTZ,
          ac.aircraft_type
        FROM s
        JOIN ap_rng o ON s.o_pick >  o.hi - o.w AND s.o_pick <= o.hi
        JOIN ap_rng d ON s.d_pick >  d.hi - d.w AND s.d_pick <= d.hi
        JOIN ac        ON ac.rn = s.ac_pick
        WHERE o.iata <> d.iata
        ORDER BY s.sched
    """).collect()

    flights = session.sql(f"SELECT COUNT(*) AS c FROM {raw}.flights").collect()[0]["C"]
    return (f"SEED complete in {db}: {name_count} names, {len(AIRPORTS)} airports, "
            f"{len(AIRCRAFT)} aircraft types, {flights} flights (schedule -270..+90 days)")
$$;
