#!/usr/bin/env bash
# scripts/deploy.sh
# Deploys ONLY the SQL files that changed in a push (fast, selective), via the
# Snowflake CLI using the JWT connection configured by the workflow.
#
# Usage: scripts/deploy.sh [BEFORE_SHA] [AFTER_SHA]
#   - With BEFORE/AFTER: deploys files changed between the two commits.
#   - Without args (e.g. manual run): deploys all tracked SQL files.
#
# sql/00_account/** is intentionally skipped: those require ACCOUNTADMIN and are a
# one-time admin step, not part of CI/CD (the service user cannot create roles/users).
set -euo pipefail

CONN="${SNOWFLAKE_CONNECTION:-prod}"
BEFORE="${1:-}"
AFTER="${2:-HEAD}"
ZERO="0000000000000000000000000000000000000000"

if [[ -n "$BEFORE" && "$BEFORE" != "$ZERO" ]]; then
  mapfile -t FILES < <(git diff --name-only "$BEFORE" "$AFTER" -- 'sql/**/*.sql' | sort)
  echo "Changed SQL between ${BEFORE:0:7}..${AFTER:0:7}:"
else
  mapfile -t FILES < <(git ls-files 'sql/**/*.sql' | sort)
  echo "Deploying all tracked SQL files:"
fi

TO_RUN=()
for f in "${FILES[@]}"; do
  if [[ "$f" == sql/00_account/* ]]; then
    echo "  skip (admin-only): $f"
    continue
  fi
  if [[ -f "$f" ]]; then
    TO_RUN+=("$f")
  else
    echo "  skip (deleted): $f"
  fi
done

if [[ ${#TO_RUN[@]} -eq 0 ]]; then
  echo "No deployable SQL changes. Done."
  exit 0
fi

for f in "${TO_RUN[@]}"; do
  echo "=== Deploying $f ==="
  snow sql -f "$f" --connection "$CONN"
done

echo "Deployment complete (${#TO_RUN[@]} file(s))."
