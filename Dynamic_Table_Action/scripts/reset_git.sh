#!/usr/bin/env bash
# Dynamic_Table_Action/scripts/reset_git.sh - return the DT demo's GitHub state to baseline.
# Pair with scripts/reset.sql (Snowflake side). Run from anywhere inside the repo.
#
# The repo holds TWO demos (Dynamic_Table_Action/ and DBT-Actions/), so this script only
# touches the DT demo:
#   1. close open PRs whose branch is not a dbt demo branch (dbt/*)
#   2. delete remote branches other than main / solution / dbt-solution / dbt/*
#   3. restore Dynamic_Table_Action/ on main from the dt-baseline-v1 tag (one commit; the
#      ruleset that protects main is paused for that push only, then re-enabled)
#   4. point dt-prod-last-good at the new main commit (prod matches baseline after reset.sql)
#   5. sync the local checkout to main
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
DEMO_DIR="Dynamic_Table_Action"
BASE_TAG="dt-baseline-v1"
LAST_GOOD_TAG="dt-prod-last-good"
KEEP_RE='^(main|solution|dbt-solution|dbt/.*)$'

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
RULESET_ID="$(gh api "repos/$REPO/rulesets" -q '.[] | select(.name=="main: PR + CI required") | .id')"

echo "== close open DT demo PRs"
gh pr list --state open --json number,headRefName -q '.[] | "\(.number) \(.headRefName)"' |
while read -r n branch; do
  [[ "$branch" =~ $KEEP_RE ]] && continue
  gh pr close "$n" --comment "Closed by DT demo reset." >/dev/null && echo "  closed #$n ($branch)"
done

echo "== delete DT demo branches"
for b in $(gh api "repos/$REPO/branches" --paginate -q '.[].name'); do
  [[ "$b" =~ $KEEP_RE ]] && continue
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
  git commit -qm "chore(dt-demo): reset Dynamic_Table_Action to $BASE_TAG"
  [ -n "$RULESET_ID" ] && gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=disabled >/dev/null
  trap '[ -n "$RULESET_ID" ] && gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=active >/dev/null' EXIT
  git push -q origin main
  gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=active >/dev/null
  trap - EXIT
  echo "  pushed $(git rev-parse --short HEAD); ruleset re-enabled"
fi

echo "== $LAST_GOOD_TAG -> main"
SHA="$(git rev-parse HEAD)"
gh api -X PATCH "repos/$REPO/git/refs/tags/$LAST_GOOD_TAG" -f sha="$SHA" -F force=true >/dev/null 2>&1 \
  || gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$LAST_GOOD_TAG" -f sha="$SHA" >/dev/null

echo "== local branches"
git fetch -q --prune --tags --force origin
git for-each-ref --format='%(refname:short)' refs/heads | grep -vE "$KEEP_RE" | xargs -r git branch -D >/dev/null 2>&1 || true
echo "Done: main = $(git rev-parse --short HEAD); $DEMO_DIR/ = $BASE_TAG"
