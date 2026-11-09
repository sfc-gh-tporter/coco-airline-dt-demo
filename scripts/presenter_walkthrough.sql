-- scripts/presenter_walkthrough.sql
-- Live demo script: "What good Snowflake CI/CD looks like - with CoCo in the loop."
-- Run section by section. This file is a presenter aid; it is NOT deployed by CI.
-- Style: SQL keywords UPPERCASE, object names lowercase.
--
-- The story
--   A pipeline change goes from a feature branch -> pull request -> automated checks in
--   Snowflake (a right-sized, zero-copy test environment per PR) -> approval-gated prod
--   deploy with audit trail, smoke test, and automatic rollback. Auth is OIDC end to end:
--   there are no Snowflake credentials stored in GitHub. CoCo writes the change, opens the
--   PR, and fixes what CI flags - it never touches prod directly.
--
-- Where you intervene
--   - Section 4/6/7: paste the CoCo prompts.
--   - Section 7: click "Review deployments -> Approve" in GitHub (the prod gate).
-- =====================================================================================

USE ROLE sysadmin;
USE WAREHOUSE airline_demo_wh;

-- -------------------------------------------------------------------------------------
-- 0. Pre-flight (before the audience joins)
-- -------------------------------------------------------------------------------------
-- Baseline: no PR schemas, no dynamic table, legacy mart populated, task suspended.
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;                         -- expect none
SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;                        -- expect none
SELECT COUNT(*) AS mart_rows FROM airline_prod.curated.route_daily_performance;

-- -------------------------------------------------------------------------------------
-- 1. The pipeline we are about to change
-- -------------------------------------------------------------------------------------
-- ~10GB generated in Snowflake: two large facts + a flights dimension.
SHOW TABLES IN SCHEMA airline_prod.staging;
SELECT * FROM airline_prod.staging.bookings LIMIT 100;
SELECT * FROM airline_prod.staging.flight_status_events LIMIT 100;

-- Today a scheduled task FULLY rebuilds the route x day KPI mart every 10 minutes.
SELECT GET_DDL('TASK', 'airline_prod.curated.refresh_route_daily_performance_task');
SELECT * FROM airline_prod.curated.route_daily_performance ORDER BY revenue_usd DESC LIMIT 10;

-- New bookings arrive (a small batch on flights departing in the next 7 days)...
CALL airline_prod.data_gen.sp_generate_airline_data(1.0, 'LIVE');
-- ...and the legacy task rescans all history to reflect them. Wait for it to finish
-- (the PR's parity test compares against this mart, so it must be current).
EXECUTE TASK airline_prod.curated.refresh_route_daily_performance_task;
SELECT state, scheduled_time, completed_time
FROM TABLE(airline_prod.information_schema.task_history(
       TASK_NAME => 'REFRESH_ROUTE_DAILY_PERFORMANCE_TASK', RESULT_LIMIT => 1));
SELECT ROUND(total_elapsed_time/1000,1) AS secs, ROUND(bytes_scanned/POW(1024,3),2) AS gb_scanned,
       rows_produced
FROM TABLE(airline_prod.information_schema.query_history(RESULT_LIMIT => 50))
WHERE query_text ILIKE 'insert overwrite into airline_prod.curated%'
ORDER BY start_time DESC LIMIT 1;

-- -------------------------------------------------------------------------------------
-- 2. The CI/CD platform (tour it before using it)
-- -------------------------------------------------------------------------------------
-- Two service identities, both OIDC (workload identity federation). No password, no key.
--   SVC_GH_ACTIONS_CI      trusts GitHub "pull_request" jobs    -> role AIRLINE_CI_RL (read-only on prod)
--   SVC_GH_ACTIONS_AIRLINE trusts GitHub "environment:prod"     -> role PROD_GH_ACTIONS_DEPLOY_RL
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_actions_ci;
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER svc_gh_actions_airline;
SHOW GRANTS TO ROLE airline_ci_rl;          -- note: SELECT on prod, OWNERSHIP only on AIRLINE_CI

-- In GitHub (show in the browser):
--   Settings -> Secrets: only SNOWFLAKE_ACCOUNT.
--   Settings -> Environments -> prod: required reviewer.
--   Settings -> Rules: main requires a pull request + the "ci" check.
--   .github/workflows/: pr.yml (checks), pr_cleanup.yml (hygiene), deploy.yml (prod).

-- -------------------------------------------------------------------------------------
-- 3. The PR test environment design (talk track)
-- -------------------------------------------------------------------------------------
-- Every PR gets schemas AIRLINE_CI.PR_<n>_STAGING / PR_<n>_CURATED containing zero-copy
-- clones of ONLY what that PR reads, changes, or affects downstream. A docs-only PR touches
-- nothing in Snowflake; a column change clones one table and its dependents. Schemas are
-- dropped when the PR closes, and a nightly sweeper removes anything orphaned.

-- -------------------------------------------------------------------------------------
-- 4. >>> Hand off to CoCo: author the change and open a PR <<<
-- -------------------------------------------------------------------------------------
/*
Replace the full-refresh task that feeds airline_prod.curated.route_daily_performance with a
single INCREMENTAL dynamic table, airline_prod.curated.route_daily_performance_dt, that
produces the same KPI columns. Use the /dynamic-tables skill to design it and the
/object-parity-test skill to add a CI parity test proving it matches the legacy table.
Don't create anything in Snowflake yourself - follow COCO.md: put the change on a branch and
open a pull request so CI can build and test it.
*/

-- -------------------------------------------------------------------------------------
-- 5. Watch CI (GitHub PR page)
-- -------------------------------------------------------------------------------------
-- The "ci" check runs in a few minutes and posts a results comment. While it runs:
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;                         -- the PR's schemas appear
-- Expect: deploy, refresh mode, parity, and incremental checks PASS; Docs coverage FAILS
-- (the new table has no column comments). The PR cannot merge while "ci" is red.

-- -------------------------------------------------------------------------------------
-- 6. >>> CoCo fixes the failing check <<<
-- -------------------------------------------------------------------------------------
/*
The CI check on my pull request failed. Find out why and fix it.
*/
-- CoCo reads the PR comment / run log, uses /change-documentation to add table + column
-- comments, and pushes to the same branch. CI re-runs and turns green.

-- -------------------------------------------------------------------------------------
-- 7. Merge -> approval-gated prod deploy
-- -------------------------------------------------------------------------------------
/*
CI is green - merge the pull request.
*/
-- In GitHub: Actions -> "Deploy (prod)" is WAITING for approval.
-- >>> Click "Review deployments" -> prod -> "Approve and deploy". <<<
-- The job deploys, smoke-tests, and moves the prod-last-good tag. On a failed smoke test it
-- rolls back automatically.

-- -------------------------------------------------------------------------------------
-- 8. Traceability: who changed prod, with what, and was it healthy?
-- -------------------------------------------------------------------------------------
USE ROLE prod_gh_actions_deploy_rl;
SELECT action, status, file_path, git_sha, actor, query_tag, started_at
FROM airline_prod.ops.deploy_log ORDER BY started_at;

-- Every prod statement carries the commit SHA in its query tag:
SELECT query_tag, query_type, ROUND(total_elapsed_time/1000,1) AS secs, user_name, role_name
FROM TABLE(airline_prod.information_schema.query_history_by_user(
       USER_NAME => 'SVC_GH_ACTIONS_AIRLINE', RESULT_LIMIT => 100))
WHERE query_tag LIKE 'gh:prod:%' ORDER BY start_time;

SHOW DYNAMIC TABLES IN SCHEMA airline_prod.curated;                        -- INCREMENTAL, in prod
USE ROLE sysadmin;
SHOW SCHEMAS LIKE 'PR\\_%' IN DATABASE airline_ci;                         -- gone: dropped on merge

-- Optional rollback drill: Actions -> "Deploy (prod)" -> Run workflow ->
--   before = HEAD~1, force_smoke_failure = true. Watch the smoke test fail and the
--   rollback restore prod; both appear in DEPLOY_LOG.

-- -------------------------------------------------------------------------------------
-- 9. RESET (after the demo). Bulk data is preserved.
-- -------------------------------------------------------------------------------------
--   snow sql -f scripts/reset.sql -c <connection>    -- Snowflake side
--   bash scripts/reset_git.sh                        -- GitHub side (PRs, branches, main, tags)
-- -------------------------------------------------------------------------------------
