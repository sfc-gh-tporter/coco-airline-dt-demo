{#- Use the custom schema name as-is (staging / intermediate / marts) instead of dbt's default
    <target_schema>_<custom>, so dev, CI and prod clones share the same layout. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ (custom_schema_name or target.schema) | trim }}
{%- endmacro %}
