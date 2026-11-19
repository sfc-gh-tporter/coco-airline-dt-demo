# Snowflake CI/CD with Cortex Code: airline demos

Two independent demos share this repo. Each has its own folder, Snowflake objects, GitHub
workflows and reset scripts.

| Folder | Demo | Workflows |
|---|---|---|
| [`Dynamic_Table_Action/`](Dynamic_Table_Action/README.md) | Replace a full-refresh task with one incremental dynamic table; raw SQL deployed by `ci.py` | `dt-pr.yml`, `dt-deploy.yml` |
| [`DBT-Actions/`](DBT-Actions/README.md) | Change a model in the middle of a dbt-managed dynamic table DAG; dev clone, slice-only parity tests, Slim CI on dbt Projects on Snowflake | `dbt-pr.yml`, `dbt-deploy.yml` |

Both PR jobs are named `ci`, so the ruleset on `main` ("PR + CI required") is satisfied by
whichever demo a pull request changes. Tags and reset scripts are per demo (`dt-*` and `dbt-*`),
so resetting one never touches the other.
