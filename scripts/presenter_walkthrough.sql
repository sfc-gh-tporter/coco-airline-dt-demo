-- scripts/presenter_walkthrough.sql
-- Live demo script: "Develop in a sandbox, ship through a pull request, deploy behind an approval."
-- Run section by section in a Snowsight worksheet (or the Workspace). Presenter aid only;
-- NOT deployed by CI. Style: SQL keywords UPPERCASE, object names lowercase.
--
-- On screen: Snowsight (Workspace git-synced to this repo + the CoCo side panel) and GitHub.
-- CoCo profile: "Data Engineering" (side panel -> Agent settings -> Profiles).
--
-- Where you intervene
--   - Section 3: create your sandbox (paste the block).
--   - Sections 4-6: paste the CoCo prompts.
--   - Section 6: create a branch, commit and push in the Workspace; open the PR in GitHub.
--   - Section 7: merge. Section 8: "Review deployments -> Approve" (the prod gate).
-- =====================================================================================

USE ROLE sysadmin;
USE WAREHOUSE airline_demo_wh;

-- -------------------------------------------------------------------------------------
-- 0. Pre-flight (before the audience joins)
-- -------------------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE airline_dev;                                      -- only INFORMATION_SCHEMA
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;                         -- none
SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;                        -- none
SELECT COUNT(*) AS mart_rows FROM airline_prod.curated.route_daily_performance;
-- Workspace: on branch main, pulled. CoCo side panel: profile "Data Engineering" applied.

-- -------------------------------------------------------------------------------------
-- 1. The pipeline we are about to change
-- -------------------------------------------------------------------------------------
-- ~10GB generated in Snowflake: two large facts + a flights dimension.
SHOW TABLES IN SCHEMA airline_prod.staging;
SELECT * FROM airline_prod.staging.bookings LIMIT 100;

-- Today a scheduled task FULLY rebuilds the route x day KPI mart every 10 minutes.
SELECT GET_DDL('TASK', 'airline_prod.curated.refresh_route_daily_performance_task');
SELECT * FROM airline_prod.curated.route_daily_performance ORDER BY revenue_usd DESC LIMIT 10;

-- New bookings arrive (a small batch on flights departing in the next 7 days)...
CALL airline_prod.data_gen.sp_generate_airline_data(1.0, 'LIVE');
-- ...and the legacy task rescans all history to reflect them. Wait until it SUCCEEDS
-- (your sandbox clones the mart next, and parity compares against it).
EXECUTE TASK airline_prod.curated.refresh_route_daily_performance_task;
SELECT state, scheduled_time, completed_time
FROM TABLE(airline_prod.information_schema.task_history(
       TASK_NAME => 'REFRESH_ROUTE_DAILY_PERFORMANCE_TASK', RESULT_LIMIT => 1));

-- -------------------------------------------------------------------------------------
-- 2. The platform: three environments, two OIDC identities, published team skills
-- -------------------------------------------------------------------------------------
--   AIRLINE_DEV.<you>    your sandbox (you, by hand)
--   AIRLINE_CI.PR_<n>    CI builds the PR's objects here, then drops the schema
--   AIRLINE_PROD         deployed only by the approved prod workflow
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_actions_ci;      -- pull_request
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_actions_airline; -- environment:prod
SHOW GRANTS TO ROLE airline_ci_rl;          -- SELECT on prod, OWNERSHIP only on AIRLINE_CI

-- The team's conventions are published skills in the Snowflake skill catalog:
SHOW CORTEX EXTENSIONS IN SCHEMA "USER$TPORTER".skill_sharing;
DESCRIBE AGENT cortex_code.config.data_engineering;     -- the "Data Engineering" profile

-- In GitHub (browser): Settings -> Secrets: only SNOWFLAKE_ACCOUNT. Environments -> prod:
-- required reviewer. Rules: main requires a PR + the "ci" check. Workflows: pr.yml, deploy.yml.

-- -------------------------------------------------------------------------------------
-- 3. Create your sandbox (zero-copy: seconds, no extra storage until rows change)
-- -------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS airline_dev.tporter;
CREATE OR REPLACE TABLE airline_dev.tporter.bookings                CLONE airline_prod.staging.bookings;
CREATE OR REPLACE TABLE airline_dev.tporter.flights                 CLONE airline_prod.staging.flights;
CREATE OR REPLACE TABLE airline_dev.tporter.flight_status_events    CLONE airline_prod.staging.flight_status_events;
CREATE OR REPLACE TABLE airline_dev.tporter.route_daily_performance CLONE airline_prod.curated.route_daily_performance;
SHOW TABLES IN SCHEMA airline_dev.tporter;

-- -------------------------------------------------------------------------------------
-- 4. >>> CoCo prompt A: build the change in the sandbox <<<
-- -------------------------------------------------------------------------------------
/*
In my sandbox airline_dev.tporter (zero-copy clones of the prod staging tables and the legacy
KPI mart), build an INCREMENTAL dynamic table airline_dev.tporter.route_daily_performance_dt
that produces the same columns as the legacy table route_daily_performance. The legacy logic
is in the task airline_prod.curated.refresh_route_daily_performance_task. Read only from the
sandbox tables, and use warehouse airline_demo_wh with a 5 minute target lag.
*/
SHOW DYNAMIC TABLES IN SCHEMA airline_dev.tporter;      -- refresh_mode INCREMENTAL

-- -------------------------------------------------------------------------------------
-- 5. >>> CoCo prompt B: prove it <<<
-- -------------------------------------------------------------------------------------
/*
Use the object-parity-test skill to compare airline_dev.tporter.route_daily_performance_dt
with airline_dev.tporter.route_daily_performance.
*/
-- CoCo reports row count, set equality both ways, aggregates, refresh mode, and an
-- incremental refresh after a small batch into the sandbox clones (prod is untouched).

-- -------------------------------------------------------------------------------------
-- 6. >>> Branch, then CoCo prompt C: package it for a pull request <<<
-- -------------------------------------------------------------------------------------
-- Workspace: create branch feat/route-daily-performance-dt.
/*
Use the pipeline-change-shipping skill to package this dynamic table for a pull request.
*/
-- CoCo writes sql/curated/dynamic_tables/route_daily_performance_dt.sql (prod names, comments
-- in the definition) and drafts the commit message.
-- Workspace: commit with that message, push. GitHub: open the pull request.

-- -------------------------------------------------------------------------------------
-- 7. Watch CI (GitHub -> PR -> Checks -> ci): each step is one check, about a minute
-- -------------------------------------------------------------------------------------
-- Plan -> Validate -> Check refresh mode -> Check documentation -> Report -> Clean up.
-- While Validate runs:
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;                         -- PR_<n> appears, then goes
-- Read the PR comment. Merge the pull request.

-- -------------------------------------------------------------------------------------
-- 8. Approval-gated prod deploy
-- -------------------------------------------------------------------------------------
-- GitHub: Actions -> "Deploy (prod)" is WAITING.
-- >>> "Review deployments" -> prod -> "Approve and deploy". <<<
-- Steps: Deploy -> Smoke test -> Record. (The DT's initial build runs in Deploy.)

-- -------------------------------------------------------------------------------------
-- 9. Traceability: who changed prod, with what, and was it healthy?
-- -------------------------------------------------------------------------------------
USE ROLE prod_gh_actions_deploy_rl;
SELECT action, status, file_path, git_sha, actor, query_tag, started_at
FROM airline_prod.ops.deploy_log ORDER BY started_at;

SELECT query_tag, query_type, ROUND(total_elapsed_time/1000,1) AS secs, user_name, role_name
FROM TABLE(airline_prod.information_schema.query_history_by_user(
       USER_NAME => 'SVC_GH_ACTIONS_AIRLINE', RESULT_LIMIT => 100))
WHERE query_tag LIKE 'gh:prod:%' ORDER BY start_time;

SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;                        -- INCREMENTAL, in prod

-- Optional rollback drill: Actions -> "Deploy (prod)" -> Run workflow ->
--   before = HEAD~1, force_smoke_failure = true. The smoke test fails, the rollback restores
--   prod, and both appear in DEPLOY_LOG.

-- -------------------------------------------------------------------------------------
-- 10. RESET (after the demo). Bulk data is preserved.
-- -------------------------------------------------------------------------------------
--   snow sql -f scripts/reset.sql -c <connection>    -- Snowflake side
--   bash scripts/reset_git.sh                        -- GitHub side (PRs, branches, main, tags)
-- -------------------------------------------------------------------------------------
