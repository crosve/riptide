-- ============================================================================
-- Step 3: admin authorization. Gated write access for riptide_api (the request
-- path) to the admin tables, enforced by RLS.
--
--   collection_grants : collection owners + tenant admins
--   collections/teams/team_members/users : tenant admins only
--   api_keys          : the acting user (own keys) or tenant admins
--   users.clearance_level / is_tenant_admin : NOT writable via the request path
--                                             (column-level GRANT; worker/owner only)
--
-- The `tenant_id = app_current_tenant()` conjunct is MANDATORY in every predicate:
-- app_collection_role()'s admin short-circuit is otherwise tenant-blind, so this
-- conjunct is the load-bearing cross-tenant guard (not redundant).
-- ============================================================================
SET search_path = public;

-- Harden app_collection_role: refuse to answer for a collection outside the
-- caller's tenant (before the admin short-circuit), and tenant-scope the grant
-- lookup. Closes the cross-tenant admin footgun.
CREATE OR REPLACE FUNCTION app_collection_role(p_collection_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM collections c
                     WHERE c.id = p_collection_id AND c.tenant_id = app_current_tenant())
      THEN NULL
    WHEN app_is_tenant_admin() THEN 'owner'
    ELSE (
      SELECT g.role
      FROM collection_grants g
      WHERE g.collection_id = p_collection_id
        AND g.tenant_id = app_current_tenant()
        AND (g.user_id = app_current_user_id() OR g.team_id = ANY (app_user_team_ids()))
      ORDER BY CASE g.role WHEN 'owner' THEN 3 WHEN 'editor' THEN 2 WHEN 'viewer' THEN 1 ELSE 0 END DESC
      LIMIT 1
    )
  END
$$;

-- --- collection_grants: collection owners (incl. tenant admins) -------------
CREATE POLICY p_api_ins ON collection_grants FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant() AND app_collection_role(collection_id) = 'owner');
CREATE POLICY p_api_upd ON collection_grants FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_collection_role(collection_id) = 'owner')
    WITH CHECK (tenant_id = app_current_tenant() AND app_collection_role(collection_id) = 'owner');
CREATE POLICY p_api_del ON collection_grants FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_collection_role(collection_id) = 'owner');

-- --- collections: tenant admins only ----------------------------------------
CREATE POLICY p_api_ins ON collections FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_upd ON collections FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin())
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_del ON collections FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin());

-- --- teams: tenant admins only ----------------------------------------------
CREATE POLICY p_api_ins ON teams FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_upd ON teams FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin())
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_del ON teams FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin());

-- --- team_members: tenant admins only (insert/delete; no mutable columns) ----
CREATE POLICY p_api_ins ON team_members FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_del ON team_members FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin());

-- --- users: tenant admins only (sensitive columns locked out via GRANT) ------
CREATE POLICY p_api_ins ON users FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_upd ON users FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin())
    WITH CHECK (tenant_id = app_current_tenant() AND app_is_tenant_admin());
CREATE POLICY p_api_del ON users FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_is_tenant_admin());

-- --- api_keys: the acting user (own keys) or tenant admins -------------------
-- WITH CHECK on UPDATE is what prevents flipping acts_as_user to a victim.
CREATE POLICY p_api_ins ON api_keys FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant()
                AND (acts_as_user = app_current_user_id() OR app_is_tenant_admin()));
CREATE POLICY p_api_upd ON api_keys FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND (acts_as_user = app_current_user_id() OR app_is_tenant_admin()))
    WITH CHECK (tenant_id = app_current_tenant()
                AND (acts_as_user = app_current_user_id() OR app_is_tenant_admin()));
CREATE POLICY p_api_del ON api_keys FOR DELETE TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND (acts_as_user = app_current_user_id() OR app_is_tenant_admin()));

-- --- Privileges (RLS confines rows; GRANT confines verbs AND columns) --------
GRANT INSERT, UPDATE, DELETE ON collections, collection_grants, teams,
    team_members, api_keys TO riptide_api;
-- users: never let the request path touch clearance_level / is_tenant_admin.
GRANT INSERT (tenant_id, email, display_name) ON users TO riptide_api;
GRANT UPDATE (email, display_name) ON users TO riptide_api;
GRANT DELETE ON users TO riptide_api;
