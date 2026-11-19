---
name: pipeline-change-shipping
description: "Package a pipeline change that was built and tested in a developer sandbox so it can ship to production through a pull request: write the object's SQL file in the repo layout, rewrite sandbox names to prod names, put table and column documentation inside the definition, and draft the team's standard commit message. Use when: a new or changed table/view/dynamic table works in the sandbox and is ready for a PR, you need to turn sandbox SQL into the repo file, add documentation before review, or write the commit message for a data change. Triggers: ship this change, package for a PR, write the repo file, get this ready for review, promote from dev, add column comments, document this table, write a commit message for this change. Does NOT deploy to prod, merge, or configure CI/CD."
---

# Pipeline Change Shipping

Our pipeline code lives in git and reaches prod only through a pull request: CI validates the
file, a reviewer approves, and the deploy workflow applies it to prod. This skill turns a change
that already works in the developer sandbox into the file the PR ships, following team
conventions, plus a standard commit message.

## Team conventions
| Convention | Rule |
| --- | --- |
| File location | `sql/<schema>/<object_type>/<object_name>.sql`, lowercase. Object types: `tables`, `dynamic_tables`, `views`, `tasks`. Example: `sql/curated/views/route_summary_v.sql`. |
| Object names in files | Always the **prod** name: `AIRLINE_PROD.<STAGING or CURATED>.<OBJECT>`. Never a sandbox (`AIRLINE_DEV...`) or CI name; CI and deploy rewrite names themselves. |
| Header | A short `--` comment block (file path, what the object is, what it replaces and why), then `USE ROLE PROD_GH_ACTIONS_DEPLOY_RL;` (the role that owns prod objects). |
| Compute | Prod objects that need a warehouse use `AIRLINE_DEMO_WH`. |
| Documentation | Required for every new or changed table, view and dynamic table: an object `COMMENT` and a comment on **every** column, written in the definition (CI fails the PR otherwise). |
| Idempotent | `CREATE OR REPLACE` for derived objects (views, dynamic tables); `CREATE ... IF NOT EXISTS` for tables that hold data. |
| SQL style | Keywords uppercase, object/column names lowercase in new code. |
| Scope | One logical change per PR. Do not edit unrelated files, generators, or `sql/00_account/` (admin bootstrap, never deployed by CI). |

## Workflow

### Step 1: Collect the sandbox definition
Get the working definition from the sandbox (`SELECT GET_DDL('<type>', '<sandbox fqn>')`, or the
SQL from this conversation). Identify every object it references.

### Step 2: Rewrite names to prod
For each sandbox reference `<DEV_DB>.<DEV_SCHEMA>.<T>`, find the prod schema that owns `<T>`
(`SELECT table_schema FROM AIRLINE_PROD.INFORMATION_SCHEMA.TABLES WHERE table_name = '<T>'`) and
rewrite it to `AIRLINE_PROD.<schema>.<T>`. The new object itself goes in the schema its layer
belongs to (marts and KPIs in `CURATED`). Show the mapping you used. Afterwards, no `AIRLINE_DEV`
string may remain in the file.

### Step 3: Document inside the definition
Do **not** run `ALTER ... COMMENT` or `COMMENT ON` against any live object for this; the
documentation ships in the file.
- Column comments in the column list, in SELECT order. For dynamic tables and views list names
  only (no types): `CREATE OR REPLACE DYNAMIC TABLE <obj> ( col_a COMMENT '...', col_b COMMENT '...' ) ...`
- Object comment as a property before `AS`: `COMMENT = '...'`.
- Comments must be meaningful: derive them from the query (grain, formula, units), e.g.
  `load_factor` = "seats sold / seat capacity, rounded to 4 decimals". No filler.

**Stopping point:** show the proposed comments for approval.

### Step 4: Write the file
Write `sql/<schema>/<object_type>/<object_name>.sql` with the header, `USE ROLE`, and the
documented definition. If the user's workspace is not a git checkout, present the full file
content so they can paste it. Optionally compile-check it (`only_compile`) - never execute it
against prod.

### Step 5: Draft the commit message
```
<type>(<scope>): <concise summary>

What:       <object> (<type / key properties>) replaces <incumbent, if any>
Why:        <rationale>
Validated:  <results from object-parity-test in the sandbox, if run>
Docs:       table + <N>/<N> columns documented

Generated with Cortex Code
```
Present it. The user creates the branch, commits, pushes and opens the PR with their normal git
flow; this skill does not push, merge, or deploy.

## Stopping Points
- Step 3: approve the comments.
- Step 5: present the file path, file content summary and commit message; stop.

## Output
One repo file in the team layout with prod names and complete documentation, and a drafted commit
message ready for the pull request.
