-- Reverse step 3: drop the admin-authz policies + grants and restore the
-- original app_collection_role body from migration 0001.
SET search_path = public;

DROP POLICY IF EXISTS p_api_ins ON collection_grants;
DROP POLICY IF EXISTS p_api_upd ON collection_grants;
DROP POLICY IF EXISTS p_api_del ON collection_grants;

DROP POLICY IF EXISTS p_api_ins ON collections;
DROP POLICY IF EXISTS p_api_upd ON collections;
DROP POLICY IF EXISTS p_api_del ON collections;

DROP POLICY IF EXISTS p_api_ins ON teams;
DROP POLICY IF EXISTS p_api_upd ON teams;
DROP POLICY IF EXISTS p_api_del ON teams;

DROP POLICY IF EXISTS p_api_ins ON team_members;
DROP POLICY IF EXISTS p_api_del ON team_members;

DROP POLICY IF EXISTS p_api_ins ON users;
DROP POLICY IF EXISTS p_api_upd ON users;
DROP POLICY IF EXISTS p_api_del ON users;

DROP POLICY IF EXISTS p_api_ins ON api_keys;
DROP POLICY IF EXISTS p_api_upd ON api_keys;
DROP POLICY IF EXISTS p_api_del ON api_keys;

REVOKE INSERT, UPDATE, DELETE ON collections, collection_grants, teams,
    team_members, api_keys FROM riptide_api;
REVOKE INSERT (tenant_id, email, display_name) ON users FROM riptide_api;
REVOKE UPDATE (email, display_name) ON users FROM riptide_api;
REVOKE DELETE ON users FROM riptide_api;

-- Restore the original (pre-0002) function definition.
CREATE OR REPLACE FUNCTION app_collection_role(p_collection_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT CASE
    WHEN app_is_tenant_admin() THEN 'owner'
    ELSE (
      SELECT g.role
      FROM collection_grants g
      WHERE g.collection_id = p_collection_id
        AND (g.user_id = app_current_user_id() OR g.team_id = ANY (app_user_team_ids()))
      ORDER BY CASE g.role WHEN 'owner' THEN 3 WHEN 'editor' THEN 2 WHEN 'viewer' THEN 1 ELSE 0 END DESC
      LIMIT 1
    )
  END
$$;
