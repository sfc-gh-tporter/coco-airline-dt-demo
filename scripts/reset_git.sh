#!/usr/bin/env bash
# scripts/reset_git.sh - return GitHub + the local clone to the demo baseline.
# Pair with scripts/reset.sql (Snowflake side). Never touches the `solution` branch.
#
#   1. close any open pull requests (the demo PR)
#   2. delete remote branches other than main / solution
#   3. rewind main to the baseline-v1 tag (the ruleset that protects main is paused for
#      the force-push only, then re-enabled)
#   4. point prod-last-good at the baseline (prod matches baseline after reset.sql)
#   5. reset the local checkout to main @ baseline-v1
set -euo pipefail

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
BASE_SHA="$(git rev-parse 'baseline-v1^{commit}')"
RULESET_ID="$(gh api "repos/$REPO/rulesets" -q '.[] | select(.name=="main: PR + CI required") | .id')"

echo "== close open PRs"
for n in $(gh pr list --state open --json number -q '.[].number'); do
  gh pr close "$n" --comment "Closed by demo reset." >/dev/null && echo "  closed #$n"
done

echo "== delete demo branches"
for b in $(gh api "repos/$REPO/branches" --paginate -q '.[].name'); do
  case "$b" in main|solution) ;; *) gh api -X DELETE "repos/$REPO/git/refs/heads/$b" && echo "  deleted $b" ;; esac
done

echo "== rewind main to baseline-v1 ($BASE_SHA)"
[ -n "$RULESET_ID" ] && gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=disabled >/dev/null
trap '[ -n "$RULESET_ID" ] && gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=active >/dev/null' EXIT
gh api -X PATCH "repos/$REPO/git/refs/heads/main" -f sha="$BASE_SHA" -F force=true >/dev/null
gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" -f enforcement=active >/dev/null
trap - EXIT
echo "  main -> $(git rev-parse --short "$BASE_SHA"); ruleset re-enabled"

echo "== prod-last-good -> baseline"
gh api -X PATCH "repos/$REPO/git/refs/tags/prod-last-good" -f sha="$BASE_SHA" -F force=true >/dev/null 2>&1 \
  || gh api -X POST "repos/$REPO/git/refs" -f ref=refs/tags/prod-last-good -f sha="$BASE_SHA" >/dev/null

echo "== local checkout"
git fetch --prune --tags --force origin
git checkout -q main
git reset -q --hard baseline-v1
git for-each-ref --format='%(refname:short)' refs/heads | grep -vxE 'main|solution' | xargs -r git branch -D >/dev/null 2>&1 || true
echo "Done: main = $(git rev-parse --short HEAD) (baseline-v1)"
