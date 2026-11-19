{#-
  Parity checks for a change to a slice of the DAG. Shared by the dev loop and CI.

    dbt run-operation snapshot_parity_baseline --args '{models: "int_flight_operations,mart_route_daily"}'
    dbt build --select state:modified+ --full-refresh ...
    dbt run-operation assert_parity           --args '{models: "int_flight_operations,mart_route_daily"}'

  snapshot_parity_baseline  zero-copy clones each model into <target db>.parity_baseline before
                            the build (same snapshot the rebuild reads, so no drift).
  assert_parity             for each model, against its baseline:
                              - row count unchanged
                              - no baseline column removed
                              - EXCEPT both ways on the baseline columns returns 0 rows
                                (existing values unchanged)
                              - dynamic table still INCREMENTAL with no fallback reason
                            New columns are allowed and reported; a model with no baseline is
                            reported as NEW. One machine-readable line per
                            model (PARITY|...) for the CI report; fails the run on any mismatch.
-#}

{% macro _parity_models(models) -%}
    {%- set names = [] -%}
    {%- for m in (models.split(',') if models is string else models) -%}
        {%- if m | trim -%}{%- do names.append(m | trim | lower) -%}{%- endif -%}
    {%- endfor -%}
    {%- set found = [] -%}
    {%- for node in graph.nodes.values() if node.resource_type == 'model' and node.name in names -%}
        {%- do found.append(node) -%}
    {%- endfor -%}
    {%- if found | length != names | length -%}
        {%- do exceptions.raise_compiler_error('parity: unknown model(s) in ' ~ names | join(', ')) -%}
    {%- endif -%}
    {%- do return(found) -%}
{%- endmacro %}

{% macro _parity_baseline_relation(node) -%}
    {%- do return(api.Relation.create(database=target.database, schema='PARITY_BASELINE', identifier=node.alias)) -%}
{%- endmacro %}

{% macro snapshot_parity_baseline(models) %}
    {%- if target.name == 'prod' -%}
        {%- do exceptions.raise_compiler_error('parity: never snapshot in prod') -%}
    {%- endif -%}
    {%- do run_query('CREATE SCHEMA IF NOT EXISTS ' ~ target.database ~ '.parity_baseline') -%}
    {%- for node in _parity_models(models) -%}
        {%- set src = api.Relation.create(database=target.database, schema=node.schema, identifier=node.alias) -%}
        {%- set dst = _parity_baseline_relation(node) -%}
        {%- if adapter.get_relation(database=src.database, schema=src.schema, identifier=src.identifier) is none -%}
            {%- do log('parity baseline: ' ~ node.name ~ ' is new (no baseline)', info=True) -%}
        {%- else -%}
            {%- do run_query('CREATE OR REPLACE TABLE ' ~ dst ~ ' CLONE ' ~ src) -%}
            {%- do log('parity baseline: ' ~ src ~ ' -> ' ~ dst, info=True) -%}
        {%- endif -%}
    {%- endfor -%}
{% endmacro %}

{% macro assert_parity(models) %}
    {%- set failures = [] -%}
    {%- set existing = [] -%}
    {%- for node in _parity_models(models) -%}
        {%- set b = _parity_baseline_relation(node) -%}
        {%- if adapter.get_relation(database=b.database, schema=b.schema, identifier=b.identifier) is none -%}
            {%- do log('PARITY|' ~ node.name ~ '|-|-|-|-|(new model)|-|NEW|no baseline to compare', info=True) -%}
        {%- else -%}
            {%- do existing.append(node) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- for node in existing -%}
        {%- set cur = api.Relation.create(database=target.database, schema=node.schema, identifier=node.alias) -%}
        {%- set base = _parity_baseline_relation(node) -%}
        {%- set base_cols = adapter.get_columns_in_relation(base) | map(attribute='name') | map('upper') | list -%}
        {%- set cur_cols = adapter.get_columns_in_relation(cur) | map(attribute='name') | map('upper') | list -%}
        {%- set removed = base_cols | reject('in', cur_cols) | list -%}
        {%- set added = cur_cols | reject('in', base_cols) | list -%}
        {%- set problems = [] -%}

        {%- if removed -%}
            {%- do problems.append('removed columns: ' ~ removed | join(' ')) -%}
            {%- set only_base, only_cur, base_rows, cur_rows = 'n/a', 'n/a', 'n/a', 'n/a' -%}
        {%- else -%}
            {%- set cols = base_cols | join(', ') -%}
            {%- set q -%}
                SELECT
                  (SELECT COUNT(*) FROM {{ base }}) AS base_rows,
                  (SELECT COUNT(*) FROM {{ cur }})  AS cur_rows,
                  (SELECT COUNT(*) FROM (SELECT {{ cols }} FROM {{ base }} EXCEPT SELECT {{ cols }} FROM {{ cur }})) AS only_base,
                  (SELECT COUNT(*) FROM (SELECT {{ cols }} FROM {{ cur }} EXCEPT SELECT {{ cols }} FROM {{ base }})) AS only_cur
            {%- endset -%}
            {%- set r = run_query(q).rows[0] -%}
            {%- set base_rows, cur_rows, only_base, only_cur = r[0], r[1], r[2], r[3] -%}
            {%- if base_rows != cur_rows -%}{%- do problems.append('row count ' ~ base_rows ~ ' -> ' ~ cur_rows) -%}{%- endif -%}
            {%- if only_base > 0 or only_cur > 0 -%}
                {%- do problems.append(only_base ~ ' baseline rows changed / ' ~ only_cur ~ ' new rows on existing columns') -%}
            {%- endif -%}
        {%- endif -%}

        {%- set dt = run_query("SHOW DYNAMIC TABLES LIKE '" ~ node.alias | upper ~ "' IN SCHEMA " ~ target.database ~ "." ~ node.schema) -%}
        {%- set mode, reason = 'n/a', '' -%}
        {%- if dt.rows | length > 0 -%}
            {%- set mode = dt.rows[0]['refresh_mode'] -%}
            {%- set reason = dt.rows[0]['refresh_mode_reason'] or '' -%}
            {%- if mode != 'INCREMENTAL' or reason | trim -%}
                {%- do problems.append('refresh_mode ' ~ mode ~ (' (' ~ reason ~ ')' if reason else '')) -%}
            {%- endif -%}
        {%- endif -%}

        {%- set status = 'FAIL' if problems else 'PASS' -%}
        {%- do log('PARITY|' ~ node.name ~ '|' ~ base_rows ~ '|' ~ cur_rows ~ '|' ~ only_base ~ '|' ~ only_cur
                   ~ '|' ~ (added | join(' ') | lower or '-') ~ '|' ~ mode ~ '|' ~ status
                   ~ '|' ~ (problems | join('; ') or '-'), info=True) -%}
        {%- if problems -%}{%- do failures.append(node.name ~ ': ' ~ problems | join('; ')) -%}{%- endif -%}
    {%- endfor -%}
    {%- if failures -%}
        {%- do exceptions.raise_compiler_error('parity FAILED: ' ~ failures | join(' | ')) -%}
    {%- endif -%}
    {%- do log('parity PASSED for ' ~ models, info=True) -%}
{% endmacro %}
