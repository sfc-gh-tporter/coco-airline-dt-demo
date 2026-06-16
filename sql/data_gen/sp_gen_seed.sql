-- data_gen/sp_gen_seed.sql
-- Builds the small, realistic reference data with Faker, then generates the FLIGHTS
-- dimension in pure SQL. Also creates the id sequences used by the fact generators.
-- DATABASE-RELATIVE: resolves objects in whatever database it executes in (prod or a
-- clone), via session.get_current_database(). Run BEFORE bulk generation.
--
--   USE DATABASE AIRLINE_PROD;  CALL DATA_GEN.SP_GEN_SEED(60000, 3250000);
--      arg1 = number of realistic passenger names (Faker)
--      arg2 = number of flights in the dimension (published schedule)

USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;

CREATE OR REPLACE PROCEDURE AIRLINE_PROD.DATA_GEN.SP_GEN_SEED(NAME_COUNT NUMBER, N_FLIGHTS NUMBER)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'faker', 'numpy', 'pandas')
  HANDLER = 'run'
AS
$$
import pandas as pd
from faker import Faker

AIRPORTS = [
    "ATL","LAX","ORD","DFW","DEN","JFK","SFO","SEA","LAS","MCO","EWR","CLT",
    "PHX","IAH","MIA","BOS","MSP","FLL","DTW","PHL","LGA","BWI","SLC","DCA",
    "SAN","IAD","TPA","BNA","AUS","MDW","HNL","DAL","PDX","STL","RDU","HOU",
    "SMF","MSY","SJC","SNA","LHR","CDG","AMS","FRA","NRT","HND","SIN","HKG",
    "DXB","YYZ","MEX","GRU","SYD","ICN","PEK","PVG","MAD","BCN","FCO","MUC",
]
AIRCRAFT = [
    ("B738",189),("A320",180),("B739",201),("A321",220),("B752",199),
    ("E175",76),("CRJ9",90),("B788",242),("A359",315),("B77W",396),
]

def run(session, name_count, n_flights):
    name_count = int(name_count)
    n_flights = int(n_flights)

    # Resolve the database we are running in (prod or a clone) - DB-relative.
    db = session.get_current_database().strip('"')
    GEN = f"{db}.DATA_GEN"
    STG = f"{db}.STAGING"

    session.sql(f"CREATE SEQUENCE IF NOT EXISTS {GEN}.BOOKING_SEQ START = 1 INCREMENT = 1").collect()
    session.sql(f"CREATE SEQUENCE IF NOT EXISTS {GEN}.EVENT_SEQ   START = 1 INCREMENT = 1").collect()

    fake = Faker()
    Faker.seed(42)
    names = [(i + 1, fake.name()) for i in range(name_count)]
    df_names = pd.DataFrame(names, columns=["NAME_ID", "FULL_NAME"])
    session.write_pandas(df_names, "NAME_POOL", database=db, schema="DATA_GEN",
                         auto_create_table=True, overwrite=True)

    df_air = pd.DataFrame([(a,) for a in AIRPORTS], columns=["IATA"])
    session.write_pandas(df_air, "AIRPORTS", database=db, schema="DATA_GEN",
                         auto_create_table=True, overwrite=True)
    df_ac = pd.DataFrame(AIRCRAFT, columns=["AIRCRAFT_TYPE", "SEAT_CAPACITY"])
    session.write_pandas(df_ac, "AIRCRAFT", database=db, schema="DATA_GEN",
                         auto_create_table=True, overwrite=True)

    n_air = len(AIRPORTS)
    n_ac = len(AIRCRAFT)

    # Published schedule: flights span ~ -300 to +60 days around today. flight_id is
    # assigned in scheduled_dep_ts order and rows are inserted sorted, so flight_id is
    # monotonic with date. This makes the fact tables (generated in flight_id order)
    # naturally date-clustered -> localized incremental refreshes can prune by date.
    session.sql(f"TRUNCATE TABLE IF EXISTS {STG}.FLIGHTS").collect()
    flights_sql = f"""
        INSERT INTO {STG}.FLIGHTS
          (flight_id, flight_number, origin, dest, route,
           scheduled_dep_ts, aircraft_type, seat_capacity)
        SELECT
            ROW_NUMBER() OVER (ORDER BY s.sched) AS flight_id,
            'XA' || LPAD(MOD(ROW_NUMBER() OVER (ORDER BY s.sched), 9000) + 100, 4, '0'),
            o.iata, d.iata, o.iata || '-' || d.iata,
            s.sched, ac.aircraft_type, ac.seat_capacity
        FROM (
            SELECT
                DATEADD('minute', UNIFORM(0, 1439, RANDOM()),
                  DATEADD('day', UNIFORM(-300, 60, RANDOM()),
                    DATE_TRUNC('day', CURRENT_TIMESTAMP())))::TIMESTAMP_NTZ AS sched,
                UNIFORM(1, {n_air}, RANDOM()) AS o_rn,
                UNIFORM(1, {n_air}, RANDOM()) AS d_rn,
                UNIFORM(1, {n_ac},  RANDOM()) AS ac_rn
            FROM TABLE(GENERATOR(ROWCOUNT => {n_flights}))
        ) s
        JOIN (SELECT iata, ROW_NUMBER() OVER (ORDER BY iata) rn FROM {GEN}.AIRPORTS) o ON o.rn = s.o_rn
        JOIN (SELECT iata, ROW_NUMBER() OVER (ORDER BY iata) rn FROM {GEN}.AIRPORTS) d ON d.rn = s.d_rn
        JOIN (SELECT aircraft_type, seat_capacity, ROW_NUMBER() OVER (ORDER BY aircraft_type) rn
              FROM {GEN}.AIRCRAFT) ac ON ac.rn = s.ac_rn
        WHERE o.iata <> d.iata
        ORDER BY s.sched
    """
    session.sql(flights_sql).collect()

    flights = session.sql(f"SELECT COUNT(*) c FROM {STG}.FLIGHTS").collect()[0]["C"]
    return (f"SEED complete in {db}: {name_count} names, {n_air} airports, {n_ac} aircraft, "
            f"{flights} flights (schedule -300..+60 days)")
$$;
