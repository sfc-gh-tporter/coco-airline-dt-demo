# tests/parity

Parity tests added by pull requests (one file per candidate object, e.g. written with the
`object-parity-test` skill). CI (`scripts/ci/ci.py`) runs every file here that references an
object the PR changes.

Contract:
- Write object names as they exist in prod (`AIRLINE_PROD.<SCHEMA>.<OBJECT>`). CI rewrites them
  to the PR's zero-copy clones in `AIRLINE_CI.PR_<n>_*` and refuses to run against prod.
- Read-only. One query whose rows each have `CHECK_NAME`, `PASSED` (boolean), `DETAIL`.
- Cover at least: row count, set equality in both directions, aggregate reconciliation.
