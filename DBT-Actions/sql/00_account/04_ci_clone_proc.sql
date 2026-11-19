-- DBT-Actions/sql/00_account/04_ci_clone_proc.sql
-- The only way CI gets a writable copy of prod.
--
-- Cloned objects keep their original owner, so a plain CLONE leaves the CI role unable to
-- rebuild anything. This owner's-rights procedure (owned by the deploy role) clones prod into
-- AIRLINE_DBT_PR_<n> or AIRLINE_DBT_DEV[_<name>] only, then hands every object in the clone to the
-- CI role. Any other name is refused, so CI can never create, replace or drop a prod object.
-- Ownership moves with REVOKE CURRENT GRANTS (COPY CURRENT GRANTS would need MANAGE GRANTS).

USE ROLE airline_dbt_deploy_rl;

CREATE OR REPLACE PROCEDURE airline_dbt_prod.ops.sp_clone_for_ci(target_db STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Zero-copy clone AIRLINE_DBT_PROD into a PR/dev database owned by AIRLINE_DBT_CI_RL'
EXECUTE AS OWNER
AS
$$
DECLARE
  db STRING DEFAULT UPPER(:target_db);
  grantee STRING DEFAULT 'AIRLINE_DBT_CI_RL';
BEGIN
  IF (NOT REGEXP_LIKE(:db, 'AIRLINE_DBT_(PR_[0-9]+|DEV(_[A-Z0-9_]+)?)')) THEN
    RETURN 'refused: ' || :db || ' (only AIRLINE_DBT_PR_<n> or AIRLINE_DBT_DEV[_<name>])';
  END IF;
  EXECUTE IMMEDIATE 'CREATE OR REPLACE DATABASE ' || :db || ' CLONE airline_dbt_prod'
                    || ' COMMENT = ''zero-copy clone of AIRLINE_DBT_PROD for CI / dev''';
  EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON ALL DYNAMIC TABLES IN DATABASE ' || :db || ' TO ROLE ' || :grantee || ' REVOKE CURRENT GRANTS';
  EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON ALL TABLES IN DATABASE '         || :db || ' TO ROLE ' || :grantee || ' REVOKE CURRENT GRANTS';
  EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON ALL VIEWS IN DATABASE '          || :db || ' TO ROLE ' || :grantee || ' REVOKE CURRENT GRANTS';
  EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE '        || :db || ' TO ROLE ' || :grantee || ' REVOKE CURRENT GRANTS';
  EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON DATABASE '                       || :db || ' TO ROLE ' || :grantee || ' REVOKE CURRENT GRANTS';
  RETURN 'cloned AIRLINE_DBT_PROD -> ' || :db || ' (owner ' || :grantee || ')';
END;
$$;

GRANT USAGE ON PROCEDURE airline_dbt_prod.ops.sp_clone_for_ci(STRING) TO ROLE airline_dbt_ci_rl;
