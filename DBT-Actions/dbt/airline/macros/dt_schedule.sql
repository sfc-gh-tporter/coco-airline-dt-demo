{#- Per-target refresh scheduling for a dynamic table model:
      {{ config(**dt_schedule('DOWNSTREAM')) }}   or   {{ config(**dt_schedule('10 minutes')) }}

    prod     Snowflake-managed refresh: scheduler ENABLE + target_lag. A recreated table
             initializes on the larger AIRLINE_DBT_INIT_WH.
    dev, ci  dbt-managed refresh: scheduler DISABLE and no target_lag, so `dbt build` refreshes
             each model synchronously and tests never read a half-refreshed table.

    Returned as a dict because a Jinja `none` inside dbt_project.yml renders as the string
    "None". -#}
{% macro dt_schedule(prod_lag) -%}
    {%- if target.name == 'prod' -%}
        {%- do return({
            'scheduler': 'ENABLE',
            'target_lag': prod_lag,
            'snowflake_initialization_warehouse': 'AIRLINE_DBT_INIT_WH'
        }) -%}
    {%- else -%}
        {%- do return({'scheduler': 'DISABLE'}) -%}
    {%- endif -%}
{%- endmacro %}
