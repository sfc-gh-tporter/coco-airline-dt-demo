# CoCo Demo: Streams + Task -> Incremental Dynamic Table (Airlines)

A reusable Cortex Code (CoCo) demo. It starts from a deliberately inefficient
airline data pipeline (append-only streams used only as a trigger for a
scheduled **full-recompute** task) and uses CoCo + the `/dynamic-tables` skill to
convert it into a single **INCREMENTAL Dynamic Table**, validated on a zero-copy
clone, then deployed to production via **GitHub Actions** with key-pair auth.

---

## Architecture

```
STAGING (1GB+/table, all generated in Snowflake)
  FLIGHTS                (structured dim)
  BOOKINGS               (structured fact)
  FLIGHT_STATUS_EVENTS   (VARIANT / JSON)
        | append-only streams (BOOKINGS_STREAM, FLIGHTS_STREAM, EVENTS_STREAM)
        v
  TASK every 5 min, gated by SYSTEM$STREAM_HAS_DATA
        -> SP_REBUILD_ROUTE_DAILY_PERFORMANCE()
             1. consume streams into STAGING.PIPELINE_AUDIT (advance offsets)
             2. CREATE OR REPLACE full scan of ALL history  <-- the inefficiency
        v
CURATED.ROUTE_DAILY_PERFORMANCE   (route x day KPI)

AFTER (CoCo writes this live):
CURATED.ROUTE_DAILY_PERFORMANCE_DT  (INCREMENTAL Dynamic Table, TARGET_LAG=1 min)
  -> one declarative object replaces 3 streams + task + proc + audit + recompute
```

| Object | Name |
|---|---|
| Prod database | `AIRLINE_PROD` |
| Dev clone (created live) | `AIRLINE_PROD_DEV_CL` |
| Schemas | `STAGING`, `CURATED`, `DATA_GEN` |
| Warehouse | `AIRLINE_DEMO_WH` |
| CI/CD role (owns all prod objects) | `PROD_GH_ACTIONS_DEPLOY_RL` |
| Service user (GH Actions) | `SVC_GH_ACTIONS_AIRLINE` |
| GitHub repo | `sfc-gh-tporter/coco-airline-dt-demo` |

---

## Repo layout (one file per object)

```
.github/workflows/deploy.yml          GitHub Actions: JWT auth + selective deploy
scripts/
  deploy.sh                           Runs only changed sql/**.sql via snow sql -f
  apply_baseline.sql                  Ordered manifest of all baseline objects
  reset.sql                           Drop clone + DT, restore legacy baseline
  presenter_walkthrough.sql           Step-2 live demo script
sql/00_account/                       role, warehouse, database, schemas, service user
sql/staging/tables/                   flights, bookings, flight_status_events, pipeline_audit
sql/staging/streams/                  append-only streams
sql/data_gen/                         Faker-seed + SQL-bulk generation sprocs
sql/curated/tables/                   route_daily_performance (legacy target)
sql/curated/procedures/               sp_rebuild_route_daily_performance (the inefficiency)
sql/curated/tasks/                    refresh_route_daily_performance_task
sql/curated/dynamic_tables/           route_daily_performance_dt (the payoff - deployed live)
sql/teardown/                         decommission_legacy_pipeline (deployed live)
keys/                                 RSA keypair (GITIGNORED)
```

---

## 1. Pre-demo setup (already built; rebuild via reset)

Everything in `AIRLINE_PROD` is owned by `PROD_GH_ACTIONS_DEPLOY_RL` and is
considered production. Data (1GB+/table) is generated in Snowflake by
`DATA_GEN.SP_GENERATE_AIRLINE_DATA(scale, mode)`.

To rebuild from scratch run `scripts/apply_baseline.sql` then generate data:
```sql
CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'SEED');
CALL AIRLINE_PROD.DATA_GEN.SP_GENERATE_AIRLINE_DATA(1.0, 'BULK');
```

## 2. Live demo flow (run with customer)

1. Walk the existing pipeline: `scripts/presenter_walkthrough.sql`
   (show streams, resume the task, run a `LIVE` batch, show the full-recompute cost).
2. Clone production:
   ```sql
   CREATE DATABASE AIRLINE_PROD_DEV_CL CLONE AIRLINE_PROD;
   ```
3. Ask CoCo (with `/dynamic-tables`) to convert the stream+task pipeline to an
   **INCREMENTAL** Dynamic Table in `AIRLINE_PROD_DEV_CL`.
4. Validate the DDL yourself in the clone (refresh_mode = INCREMENTAL, row parity).
5. Have CoCo commit the DT to `main` and push -> GitHub Actions deploys to prod.
6. Decommission the legacy stream + task + target via `sql/teardown/`.

## 3. Reset

```sql
-- Snowflake side (run via CoCo or a worksheet):
!source scripts/reset.sql   -- drops AIRLINE_PROD_DEV_CL, drops DT, restores legacy objects
```
```bash
# Git side (main only; never touch the solution branch):
git reset --hard baseline-v1 && git push --force-with-lease origin main
```

Bulk data is preserved via zero-copy clone semantics and is NOT regenerated on reset.

### Git model (hybrid)
- `main` @ tag `baseline-v1` = the "before" state shown to customers.
- `solution` branch = proven DT + teardown commit, cherry-pick safety net if live
  authoring stumbles: `git cherry-pick <solution-commit>`.
- Reset only rewinds `main`; `solution` is never modified.
