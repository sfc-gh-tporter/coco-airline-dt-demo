#!/usr/bin/env bash
# DBT-Actions/scripts/reset.sh - return the dbt demo to its baseline (GitHub + Snowflake).
#
#   bash DBT-Actions/scripts/reset.sh [<snowflake connection>]     (default connection: demo156)
#
# The repo also holds the DT demo, so only dbt demo objects are touched:
#   1. close open PRs from dbt/* branches and delete those branches (dbt-solution is kept)
#   2. restore DBT-Actions/ on main from tag dbt-baseline-v1 (direct push; repo admins bypass
#      the main ruleset; "[skip ci]" so the prod deploy workflow does not fire)
#   3. Snowflake: drop the dev / PR clones, empty the deploy log (scripts/reset.sql)
#   4. redeploy the baseline dbt project to prod and recreate ONLY the slice the demo changed
#      (same changed_slice selector as CI, compared to prod's last successful run)
#   5. point dbt-prod-last-good at main
set -euo pipefail

CONN="${1:-demo156}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
DEMO_DIR="DBT-Actions"
BASE_TAG="dbt-baseline-v1"
LAST_GOOD_TAG="dbt-prod-last-good"
PROJECT="AIRLINE_DBT_PROD.DBT.AIRLINE_DBT_PROD_PROJECT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo "== close dbt demo PRs and delete dbt/* branches"
gh pr list --state open --json number,headRefName -q '.[] | select(.headRefName | startswith("dbt/")) | .number' |
while read -r n; do gh pr close "$n" --delete-branch --comment "Closed by dbt demo reset." >/dev/null && echo "  closed #$n"; done
for b in $(gh api "repos/$REPO/branches" --paginate -q '.[].name | select(startswith("dbt/"))'); do
  gh api -X DELETE "repos/$REPO/git/refs/heads/$b" && echo "  deleted $b"
done

echo "== restore $DEMO_DIR/ on main from $BASE_TAG"
git fetch --prune --tags --force origin
git checkout -q main
git reset -q --hard origin/main
git rm -rq --ignore-unmatch "$DEMO_DIR"
git checkout "$BASE_TAG" -- "$DEMO_DIR"
if git diff --cached --quiet; then
  echo "  $DEMO_DIR/ already matches $BASE_TAG"
else
  git commit -qm "chore(dbt-demo): reset DBT-Actions to $BASE_TAG [skip ci]"
  git push -q origin main
  echo "  pushed $(git rev-parse --short HEAD)"
fi

echo "== Snowflake: drop dev / PR clones, empty deploy log"
snow sql -f "$DEMO_DIR/scripts/reset.sql" -c "$CONN" >/dev/null

echo "== prod: redeploy baseline project, recreate only the changed slice"
snow dbt deploy AIRLINE_DBT_PROD_PROJECT --source "$DEMO_DIR/dbt/airline" --database AIRLINE_DBT_PROD --schema DBT \
  --dbt-version 1.12.3 --default-target prod --external-access-integration AIRLINE_DBT_PKG_EAI \
  -c "$CONN" --role AIRLINE_DBT_DEPLOY_RL --warehouse AIRLINE_DBT_WH >/dev/null
snow sql -c "$CONN" --role AIRLINE_DBT_DEPLOY_RL --warehouse AIRLINE_DBT_WH -q "
  EXECUTE DBT PROJECT $PROJECT
    ARGS = 'build --selector changed_slice --full-refresh --state ./imports/state --target prod'
    ENV_VARS = ('DBT_QUERY_TAG' = 'dbt-demo:reset')
    IMPORTS = (SYSTEM\$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET('$PROJECT') AS 'state')" \
  | grep -oE 'Done\. PASS=[0-9]+ WARN=[0-9]+ ERROR=[0-9]+ SKIP=[0-9]+|No nodes selected' || true

echo "== $LAST_GOOD_TAG -> main"
SHA="$(git rev-parse HEAD)"
gh api -X PATCH "repos/$REPO/git/refs/tags/$LAST_GOOD_TAG" -f sha="$SHA" -F force=true >/dev/null 2>&1 \
  || gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$LAST_GOOD_TAG" -f sha="$SHA" >/dev/null

git for-each-ref --format='%(refname:short)' refs/heads | grep -E '^dbt/' | xargs -r git branch -D >/dev/null 2>&1 || true
echo "Done: main = $(git rev-parse --short HEAD); $DEMO_DIR/ = $BASE_TAG; prod slice rebuilt from baseline"
