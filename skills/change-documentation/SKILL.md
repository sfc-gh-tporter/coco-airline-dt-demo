---
name: change-documentation
description: "Document a Snowflake object for discoverability and write a structured git commit message for a data change. Use when: a table/view/dynamic table is missing column or table comments, you want to improve data discoverability, you need descriptions added before review, or you need a clear commit message / change summary for a data-model change. Triggers: add column comments, document this table, missing descriptions, undocumented columns, improve discoverability, comment the columns, write a commit message for this change, summarize this change for the commit. This skill ONLY adds documentation and drafts a commit message - it does NOT deploy, push, or configure CI/CD."
---

# Change Documentation

Two jobs that finish a data-model change well: (1) make the object **discoverable** by ensuring the
table and every column carry meaningful comments, and (2) draft a **standardized git commit message**
that summarizes the change. Good column comments also make future semantic-view creation far easier.

## When to Use
- A new/changed object (e.g. a dynamic table that replaced a legacy table) has no/partial comments.
- You want a consistent, informative commit message for a data change before committing.

## When NOT to Use / Not to Be Confused With
- This skill does **not** deploy, push to git, or configure GitHub Actions / CI/CD / service accounts /
  secrets. Provisioning GitHub Actions deployment is a separate skill (`snowflake-cicd-github-actions`)
  and is unrelated to documenting a change. This skill only *drafts* a commit message - the user (or
  CoCo's normal git ability) performs the actual commit/push.

## Workflow

### Step 1: Documentation audit
**Goal:** find what is undocumented on the target object.

1. `DESCRIBE TABLE <object>` and check `SHOW ... ` / `GET_DDL` for an object-level `COMMENT` and
   per-column comments.
2. List columns missing a comment and whether the table itself has one.

### Step 2: Generate + apply comments
**Goal:** meaningful, accurate descriptions (not filler).

1. Propose a one-line description per undocumented column (derive meaning from the column name, type,
   and the object's query/definition - e.g. `load_factor` = "seats sold / seat capacity"). Propose a
   table-level comment summarizing grain + purpose.
2. **Stopping point:** present the proposed comments for approval.
3. Apply with `ALTER TABLE <object> ALTER COLUMN <col> COMMENT '...'` for columns and
   `COMMENT ON DYNAMIC TABLE <object> IS '...'` (or `COMMENT ON TABLE ...`) for the object. These work
   on dynamic tables too and are non-disruptive (no rebuild). Verify coverage via
   `INFORMATION_SCHEMA.COLUMNS.COMMENT`.
4. Report coverage, e.g. "table + 8/8 columns documented."

**In a repo with CI** (changes ship as pull requests, e.g. `COCO.md` says so, or the object only
exists in a PR test environment): do **not** run `ALTER`/`COMMENT ON` against live objects. Put the
documentation in the object's SQL definition in the branch instead, so it ships with the change and
CI can verify it:
- Column comments in the column list:
  `CREATE OR REPLACE DYNAMIC TABLE <obj> ( col_a COMMENT '...', col_b COMMENT '...', ... ) TARGET_LAG = ...`
  (every output column must be listed, in SELECT order; names only, no types, for dynamic tables).
- Object comment as a property: `COMMENT = '...'` before `AS`.
- Commit to the same branch and push; the CI docs check re-runs on the pull request.

(Optional light callout: flag obviously sensitive columns - names, emails, ids - as a note for the
user. Do not enforce masking/classification here; that is out of scope.)

### Step 3: Draft the commit message
**Goal:** a consistent, reviewable commit message for the change.

Compose using this format (fill from context; include parity results if an
`object-parity-test` was run):

```
<type>(<scope>): <concise summary>

What:       <object> (<type/key props>) replaces <incumbent, if any>
Why:        <rationale, e.g. incremental refresh vs full recompute>
Validated:  <parity PASS/FAIL summary; incremental confirmed if applicable>
Docs:       <table + N/N columns documented>

Generated with Cortex Code
```

Present the drafted message. The user commits/pushes with their normal git flow (this skill does not
push).

## Stopping Points
- ✋ Step 2: approve proposed comments before applying.
- ✋ Step 3: present the drafted commit message (do not commit/push from this skill).

## Output
- The object with table + column comments applied (coverage reported).
- A drafted, standardized git commit message summarizing the change.
