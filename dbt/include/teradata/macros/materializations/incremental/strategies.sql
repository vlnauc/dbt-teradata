
{% macro teradata__get_incremental_default_sql(arg_dict) %}

    {% do return(get_incremental_append_sql(arg_dict)) %}

{% endmacro %}


{% macro teradata__get_incremental_append_sql(target_relation, tmp_relation,dest_columns) %}

  {% do return(get_insert_into_sql(target_relation, tmp_relation,  dest_columns)) %}

{% endmacro %}


{% macro get_insert_into_sql(target_relation, tmp_relation, dest_columns) %}

    {%- set dest_cols_csv = get_quoted_csv(dest_columns | map(attribute="name")) -%}

    insert into {{ target_relation }} ({{ dest_cols_csv }})
        select {{ dest_cols_csv }}
        from {{ tmp_relation }}
    
{% endmacro %}


{% macro teradata__get_delete_insert_merge_sql(target_relation, tmp_relation, unique_key, dest_columns, incremental_predicates) %}
    {%- set dest_cols_csv = dest_columns | map(attribute='quoted') | join(', ') -%}

    {%- if unique_key -%}
    {% call statement('delete_table') %}
        {% if unique_key is sequence and unique_key is not string %}
            delete from {{target_relation }}
            where (
                {% for key in unique_key %}
                    {{ tmp_relation }}.{{ key }} = {{ target_relation }}.{{ key }}
                    {{ "and " if not loop.last}}
                {% endfor %}
                {% if incremental_predicates %}
                    {% for predicate in incremental_predicates %}
                        and {{ predicate }}
                    {% endfor %}
                {% endif %}
            );
        {% else %}    
            DELETE
            FROM {{ target_relation }}
            WHERE ({{ unique_key }}) IN (
                SELECT ({{ unique_key }})
                FROM {{ tmp_relation }}
            )
            {%- if incremental_predicates %}
                {% for predicate in incremental_predicates %}
                    and {{ predicate }}
                {% endfor %}
            {%- endif -%};

        {% endif %}
    {% endcall %}
    {%- endif %}
    INSERT INTO {{ target_relation }} ({{ dest_cols_csv }})
       SELECT {{ dest_cols_csv }}
       FROM {{ tmp_relation }}
    ;
{%- endmacro %}


{% macro teradata__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates=none) -%}
    {%- set predicates = [] if incremental_predicates is none else [] + incremental_predicates -%}
    {%- set dest_cols_csv = get_quoted_csv(dest_columns | map(attribute="name")) -%}
    {%- set merge_update_columns = config.get('merge_update_columns') -%}
    {%- set merge_exclude_columns = config.get('merge_exclude_columns') -%}
    {%- set update_columns = get_merge_update_columns(merge_update_columns, merge_exclude_columns, dest_columns) -%}
    {%- set sql_header = config.get('sql_header', none) -%}

    {% if unique_key %}
        {% if unique_key is sequence and unique_key is not mapping and unique_key is not string %}
            {% for key in unique_key %}
                {% set this_key_match %}
                    DBT_INTERNAL_SOURCE.{{ key }} = DBT_INTERNAL_DEST.{{ key }}
                {% endset %}
                {% do predicates.append(this_key_match) %}
            {% endfor %}
        {% else %}
            {% set unique_key_match %}
                DBT_INTERNAL_SOURCE.{{ unique_key }} = DBT_INTERNAL_DEST.{{ unique_key }}
            {% endset %}
            {% do predicates.append(unique_key_match) %}
        {% endif %}
    {% else %}
        {% set error_msg= "Unique key is required for merge incremental strategy, please provide unique key in configuration and try again
        or consider using Append strategy" %}
        {% do exceptions.CompilationError(error_msg) %}
    {% endif %}

    {{ sql_header if sql_header is not none }}

    merge into {{ target }} as DBT_INTERNAL_DEST
        using {{ source }} as DBT_INTERNAL_SOURCE
        on {{"(" ~ predicates | join(") and (") ~ ")"}}

    {% if unique_key %}
    when matched then update set
        {% set quoted_keys = [] %}
        {% if unique_key is sequence and unique_key is not mapping and unique_key is not string %}
            {% for key in unique_key %}
                {% set quoted_key = adapter.quote(key) %}
                {% do quoted_keys.append(quoted_key) %}
            {% endfor %}
        {% else %}
            {% do quoted_keys.append(adapter.quote(unique_key)) %}
        {% endif %}

        {% set final_result = [] %}
        {% for column_name in update_columns -%}
            {% if column_name not in quoted_keys %}
                {% set snippet %}
                    {{column_name}}=DBT_INTERNAL_SOURCE.{{ column_name }}
                {% endset %}
                {% do final_result.append(snippet) %}
            {% endif %}
        {% endfor %}

        {{ final_result | join(',')}}
    {% endif %}

    when not matched then insert
        ({{ dest_cols_csv }})
    values
        (
            {% for column in dest_columns -%}
                DBT_INTERNAL_SOURCE.{{ adapter.quote(column.name) }}
                {%- if not loop.last %}, {% endif %}
            {%- endfor %}
        )

{% endmacro %}

{% macro teradata__get_incremental_valid_history_sql(target, source, unique_key, valid_period, valid_from, valid_to, use_valid_to_time, resolve_conflicts) -%}
    {{ log("**************** in teradata__get_incremental_valid_history_sql macro")  }}
    {{ log("**************** target: " ~ target)  }}
    {{ log("**************** source: " ~ source)  }}
    {{ log("**************** unique_key: " ~ unique_key)  }}
    {{ log("**************** valid_period: " ~ valid_period)  }}
    {{ log("**************** valid_from: " ~ valid_from)  }}
    {{ log("**************** valid_to: " ~ valid_to)  }}
    {{ log("**************** use_valid_to_time: " ~ use_valid_to_time)  }}
    {{ log("**************** resolve_conflicts: " ~ resolve_conflicts)  }}
    {%- set exclude_columns = [unique_key , valid_from] -%}

    {%- set source_columns = adapter.get_columns_in_relation(source) -%}
    {{ log("**************** source_columns: " ~ source_columns)  }}

    {%- set target_columns = adapter.get_columns_in_relation(target) -%}
    {{ log("**************** target_columns: " ~ target_columns)  }}

    {% if unique_key %}
        {% if resolve_conflicts == "yes" %}
            {% if use_valid_to_time == "no" %}
                {% set end_date= "'9999-12-31 23:59:59.9999'" %}
            {% endif %}
             {% call statement('dropping existing staging tables') %}
                drop table hist_prep_1;
            {% endcall %}
            {% call statement('creating staging tables') %}
                create set table hist_prep_1 as {{ target }} with no data ;
            {% endcall %}
            {% call statement('removing_duplicates') %}
                insert into  hist_prep_1
                        sel distinct
                    {{ unique_key }}
                    ,PERIOD({{ valid_from }}, {{ end_date }} (timestamp))
                    ,Value_txt
                    from {{ source }}
                    qualify rank() over(partition by {{ unique_key }}, {{ valid_from }} order by Value_txt)=1;
            {% endcall %}
            {% call statement('dropping existing staging tables') %}
                drop table hist_prep_2;
            {% endcall %}
            {% call statement('creating staging tables') %}
                create set table hist_prep_2 as {{ target }} with no data ;
            {% endcall %}
            {% call statement('adjust overlapping slices') %}
                ins hist_prep_2
                sel
                {{ unique_key }}
                ,PERIOD(
                    begin(Valid_per)
                    ,coalesce(lead(begin(Valid_per)) over(partition by {{ unique_key }} order by begin(Valid_per)),({{ end_date }}(timestamp)))
                 )
                ,Value_txt
                from
                (
                    sel * from hist_prep_1
                    union
                    sel * from  {{ target }} t
                    where exists
                    (	sel 1
                        from hist_prep_1 s
                        where s.{{ unique_key }}=t.{{ unique_key }}
                        and s.Valid_per OVERLAPS t.Valid_per
                    )
                    and not exists
                    (	sel 1
                        from hist_prep_1 s
                        where s.{{ unique_key }}=t.{{ unique_key }}
                        and
                        (
                        begin(s.Valid_per)=begin(t.Valid_per)
                        or s.Valid_per contains t.Valid_per
                        )
                    )
                ) a;
            {% endcall %}
            {% call statement('dropping existing staging tables') %}
                drop table hist_prep_3;
            {% endcall %}
            {% call statement('creating staging tables') %}
                create set table hist_prep_3 as {{ target }} with no data;
            {% endcall %}
            {% call statement('compact history') %}
                ins hist_prep_3
                with subtbl as (sel * from hist_prep_2)
                sel {{ unique_key }}, Valid_per, Value_txt
                FROM TABLE
                (
                TD_SYSFNLIB.TD_NORMALIZE_MEET
                (
                NEW VARIANT_TYPE(subtbl.{{ unique_key }}, Value_txt), subtbl.Valid_per
                )
                RETURNS ({{ unique_key }} INT, Value_txt VARCHAR(1000), Valid_per PERIOD(TIMESTAMP(6)))
                HASH BY {{ unique_key }}
                LOCAL ORDER BY {{ unique_key }}, Value_txt, Valid_per
                )
                AS DT({{ unique_key }}, Value_txt, Valid_per);
            {% endcall %}
            del from  {{ target }} t
            where exists
            (sel 1 from hist_prep_3 s where s.{{ unique_key }}=t.{{ unique_key }} and s.Valid_per overlaps t.Valid_per);
            ins  {{ target }} sel * from hist_prep_3;
        {% else %}
            {% set error_msg= "Failed" %}
            {% do exceptions.CompilationError(error_msg) %}
        {% endif %}
    {% else %}
        {% set error_msg= "Unique key is required for valid_history incremental strategy, please provide unique key in configuration and try again" %}
        {% do exceptions.CompilationError(error_msg) %}
    {% endif %}
{% endmacro %}