-- ============================================================================
-- riptide schema. Load this as the (non-superuser) schema owner.
-- Extensions and roles come from bootstrap.sql, which must run first.
--
-- Isolation model (do not weaken):
--   * every tenant-owned table has tenant_id + UNIQUE (tenant_id, id)
--   * foreign keys are composite (tenant_id, id): a row can never point across tenants
--   * ENABLE + FORCE row-level security; the app connects as riptide_api / riptide_worker
--   * session context is set per request: app.tenant_id, app.user_id (SET LOCAL)
--   * a missing app.tenant_id yields zero rows (fail closed)
-- ============================================================================

SET search_path = public;

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

CREATE TABLE tenants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    kms_key_ref text,                       -- per-tenant envelope-encryption master key
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id              uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    email           text NOT NULL,
    display_name    text,
    clearance_level smallint NOT NULL DEFAULT 0 CHECK (clearance_level BETWEEN 0 AND 3),
    is_tenant_admin boolean  NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, email),
    FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
);

CREATE TABLE teams (
    id         uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, name),
    FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
);

CREATE TABLE team_members (
    tenant_id uuid NOT NULL,
    team_id   uuid NOT NULL,
    user_id   uuid NOT NULL,
    added_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, team_id, user_id),
    FOREIGN KEY (tenant_id, team_id) REFERENCES teams (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE collections (
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, name),
    FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
);

-- One grant = one principal (a team OR a single user, never both) with one role.
CREATE TABLE collection_grants (
    id            uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL,
    collection_id uuid NOT NULL,
    team_id       uuid,
    user_id       uuid,
    role          text NOT NULL CHECK (role IN ('viewer', 'editor', 'owner')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    CHECK ((team_id IS NOT NULL) <> (user_id IS NOT NULL)),   -- exactly one principal
    FOREIGN KEY (tenant_id, collection_id) REFERENCES collections (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, team_id)       REFERENCES teams (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, user_id)       REFERENCES users (tenant_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX uq_grant_team ON collection_grants (tenant_id, collection_id, team_id) WHERE team_id IS NOT NULL;
CREATE UNIQUE INDEX uq_grant_user ON collection_grants (tenant_id, collection_id, user_id) WHERE user_id IS NOT NULL;

-- API keys act as a specific user and can only narrow that user's access.
CREATE TABLE api_keys (
    id            uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL,
    acts_as_user  uuid NOT NULL,
    key_prefix    text NOT NULL UNIQUE,     -- public lookup handle
    key_hash      text NOT NULL,            -- hash of the secret; verified in constant time
    scopes        text[] NOT NULL DEFAULT '{}',
    collection_id uuid,                     -- optional: narrow to a single collection
    revoked_at    timestamptz,
    expires_at    timestamptz,
    last_used_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, acts_as_user)  REFERENCES users (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, collection_id) REFERENCES collections (tenant_id, id) ON DELETE SET NULL
);

CREATE TABLE documents (
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL,
    collection_id  uuid NOT NULL,
    title          text NOT NULL,
    classification smallint NOT NULL DEFAULT 0 CHECK (classification BETWEEN 0 AND 3),
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, collection_id) REFERENCES collections (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE document_versions (
    id                   uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL,
    document_id          uuid NOT NULL,
    version_no           int  NOT NULL,
    content_sha256       text NOT NULL,                 -- dedupe identical uploads
    idempotency_key      text,                          -- dedupe duplicate requests
    status               text NOT NULL DEFAULT 'queued'
                           CHECK (status IN ('queued','processing','indexed','failed','superseded')),
    raw_object_key       text,                          -- bronze
    canonical_object_key text,                          -- silver
    pipeline_version     text,                          -- which chunking code produced it
    created_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, document_id, version_no),
    UNIQUE (tenant_id, document_id, content_sha256),
    FOREIGN KEY (tenant_id, document_id) REFERENCES documents (tenant_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX uq_version_idempotency ON document_versions (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

-- One job per (version, stage). run_after drives exponential backoff; dead = DLQ.
CREATE TABLE ingestion_jobs (
    id                  uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    document_version_id uuid NOT NULL,
    stage               text NOT NULL,
    status              text NOT NULL DEFAULT 'queued'
                          CHECK (status IN ('queued','processing','done','failed','dead')),
    attempts            int  NOT NULL DEFAULT 0,
    max_attempts        int  NOT NULL DEFAULT 5,
    run_after           timestamptz NOT NULL DEFAULT now(),
    last_error          text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, document_version_id, stage),
    FOREIGN KEY (tenant_id, document_version_id) REFERENCES document_versions (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX ix_jobs_claim ON ingestion_jobs (status, run_after);

CREATE TABLE chunks (
    id                  uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    document_version_id uuid NOT NULL,
    document_id         uuid NOT NULL,
    collection_id       uuid NOT NULL,
    parent_chunk_id     uuid,
    ordinal             int  NOT NULL,
    content             text NOT NULL,
    content_sha256      text NOT NULL,
    token_count         int,
    section_path        text,
    contextual_header   text,                 -- "Doc > Section > Subsection"
    is_current          boolean NOT NULL DEFAULT true,
    -- ACL snapshot, kept in sync by triggers. Retrieval filters on these columns.
    allowed_team_ids    uuid[]   NOT NULL DEFAULT '{}',
    allowed_user_ids    uuid[]   NOT NULL DEFAULT '{}',
    classification      smallint NOT NULL DEFAULT 0,
    tsv                 tsvector GENERATED ALWAYS AS
                          (to_tsvector('english', coalesce(contextual_header,'') || ' ' || content)) STORED,
    created_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, document_version_id) REFERENCES document_versions (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, document_id)         REFERENCES documents (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, collection_id)       REFERENCES collections (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, parent_chunk_id)     REFERENCES chunks (tenant_id, id) ON DELETE SET NULL
);
CREATE INDEX ix_chunks_version   ON chunks (document_version_id);
CREATE INDEX ix_chunks_current   ON chunks (collection_id) WHERE is_current;
CREATE INDEX ix_chunks_tsv       ON chunks USING gin (tsv);
CREATE INDEX ix_chunks_teams     ON chunks USING gin (allowed_team_ids);

-- Platform-level (not tenant-owned): embedding models are shared infrastructure.
CREATE TABLE embedding_models (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    dimensions int  NOT NULL CHECK (dimensions > 0),
    params     jsonb NOT NULL,              -- frozen once registered (model_version, prefixes, ...)
    status     text NOT NULL DEFAULT 'building' CHECK (status IN ('building','active','retired')),
    is_default boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, params),
    CHECK (NOT is_default OR status = 'active')   -- only an active model can be default
);
CREATE UNIQUE INDEX one_default_model ON embedding_models ((is_default)) WHERE is_default;

-- Vectors from several models can coexist (keyed by chunk + model). Column is
-- untyped vector; each model gets its own partial HNSW index cast to its dims.
CREATE TABLE chunk_embeddings (
    tenant_id  uuid NOT NULL,
    chunk_id   uuid NOT NULL,
    model_id   uuid NOT NULL,
    embedding  vector NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (chunk_id, model_id),
    FOREIGN KEY (tenant_id, chunk_id) REFERENCES chunks (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (model_id)            REFERENCES embedding_models (id) ON DELETE RESTRICT
);
CREATE INDEX ix_emb_model ON chunk_embeddings (model_id);

-- Append-only.
CREATE TABLE audit_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   uuid NOT NULL,
    user_id     uuid,
    action      text NOT NULL,
    object_type text,
    object_id   uuid,
    details     jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_tenant ON audit_log (tenant_id, created_at);

-- ----------------------------------------------------------------------------
-- Session-context helpers (fail closed: NULL setting -> NULL -> no rows)
-- ----------------------------------------------------------------------------

CREATE FUNCTION app_current_tenant() RETURNS uuid
    LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

CREATE FUNCTION app_current_user_id() RETURNS uuid
    LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

CREATE FUNCTION app_current_clearance() RETURNS smallint
    LANGUAGE sql STABLE AS
$$ SELECT clearance_level FROM users
   WHERE id = app_current_user_id() AND tenant_id = app_current_tenant() $$;

CREATE FUNCTION app_is_tenant_admin() RETURNS boolean
    LANGUAGE sql STABLE AS
$$ SELECT COALESCE((SELECT is_tenant_admin FROM users
                    WHERE id = app_current_user_id() AND tenant_id = app_current_tenant()), false) $$;

CREATE FUNCTION app_user_team_ids() RETURNS uuid[]
    LANGUAGE sql STABLE AS
$$ SELECT COALESCE(array_agg(team_id), '{}') FROM team_members
   WHERE user_id = app_current_user_id() AND tenant_id = app_current_tenant() $$;

-- Effective role = highest of the direct grant and the user's teams' grants;
-- tenant admins are owner everywhere. SECURITY DEFINER so it can read
-- collection_grants without recursing into that table's own RLS policy.
CREATE FUNCTION app_collection_role(p_collection_id uuid) RETURNS text
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

-- ----------------------------------------------------------------------------
-- ACL snapshot maintenance
-- ----------------------------------------------------------------------------

-- On chunk insert, stamp the current grant principals + the document classification.
CREATE FUNCTION app_tg_chunk_acl_snapshot() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    NEW.allowed_team_ids := COALESCE(
        (SELECT array_agg(team_id) FROM collection_grants
         WHERE collection_id = NEW.collection_id AND team_id IS NOT NULL), '{}');
    NEW.allowed_user_ids := COALESCE(
        (SELECT array_agg(user_id) FROM collection_grants
         WHERE collection_id = NEW.collection_id AND user_id IS NOT NULL), '{}');
    NEW.classification := COALESCE(
        (SELECT classification FROM documents WHERE id = NEW.document_id), NEW.classification);
    RETURN NEW;
END
$$;
CREATE TRIGGER tg_chunk_acl_snapshot BEFORE INSERT ON chunks
    FOR EACH ROW EXECUTE FUNCTION app_tg_chunk_acl_snapshot();

-- When grants change, re-stamp every chunk in the affected collection.
-- SECURITY DEFINER so a grant change made by any role still propagates to chunks.
CREATE FUNCTION app_sync_collection_acl(p_collection_id uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER SET search_path = public AS
$$
  UPDATE chunks c SET
    allowed_team_ids = COALESCE((SELECT array_agg(team_id) FROM collection_grants
                                 WHERE collection_id = p_collection_id AND team_id IS NOT NULL), '{}'),
    allowed_user_ids = COALESCE((SELECT array_agg(user_id) FROM collection_grants
                                 WHERE collection_id = p_collection_id AND user_id IS NOT NULL), '{}')
  WHERE c.collection_id = p_collection_id;
$$;

CREATE FUNCTION app_tg_grant_sync() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$$
BEGIN
    PERFORM app_sync_collection_acl(COALESCE(NEW.collection_id, OLD.collection_id));
    RETURN NULL;
END
$$;
CREATE TRIGGER tg_grant_sync AFTER INSERT OR UPDATE OR DELETE ON collection_grants
    FOR EACH ROW EXECUTE FUNCTION app_tg_grant_sync();

-- When a document is reclassified, propagate to its chunks.
CREATE FUNCTION app_tg_doc_classification_sync() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$$
BEGIN
    IF NEW.classification IS DISTINCT FROM OLD.classification THEN
        UPDATE chunks SET classification = NEW.classification WHERE document_id = NEW.id;
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER tg_doc_classification_sync AFTER UPDATE OF classification ON documents
    FOR EACH ROW EXECUTE FUNCTION app_tg_doc_classification_sync();

-- ----------------------------------------------------------------------------
-- Embedding-model integrity
-- ----------------------------------------------------------------------------

-- name / dimensions / params are frozen once a model row exists.
CREATE FUNCTION app_tg_model_immutable() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.name       IS DISTINCT FROM OLD.name
    OR NEW.dimensions IS DISTINCT FROM OLD.dimensions
    OR NEW.params     IS DISTINCT FROM OLD.params THEN
        RAISE EXCEPTION 'embedding_models.name/dimensions/params are immutable once registered';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER tg_model_immutable BEFORE UPDATE ON embedding_models
    FOR EACH ROW EXECUTE FUNCTION app_tg_model_immutable();

-- Reject wrong-size vectors and vectors for a retired model.
CREATE FUNCTION app_tg_validate_embedding() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE m_dims int; m_status text;
BEGIN
    SELECT dimensions, status INTO m_dims, m_status FROM embedding_models WHERE id = NEW.model_id;
    IF m_status IS NULL THEN
        RAISE EXCEPTION 'unknown embedding model %', NEW.model_id;
    END IF;
    IF m_status = 'retired' THEN
        RAISE EXCEPTION 'cannot store embeddings for retired model %', NEW.model_id;
    END IF;
    IF vector_dims(NEW.embedding) <> m_dims THEN
        RAISE EXCEPTION 'embedding has % dims but model % expects %',
            vector_dims(NEW.embedding), NEW.model_id, m_dims;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER tg_validate_embedding BEFORE INSERT OR UPDATE ON chunk_embeddings
    FOR EACH ROW EXECUTE FUNCTION app_tg_validate_embedding();

-- Build the per-model partial HNSW index, cast to that model's dimensions.
-- SECURITY DEFINER so the worker (not the table owner) can trigger index creation.
CREATE FUNCTION create_embedding_index(p_model_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$$
DECLARE d int;
BEGIN
    SELECT dimensions INTO d FROM embedding_models WHERE id = p_model_id;
    IF d IS NULL THEN RAISE EXCEPTION 'unknown embedding model %', p_model_id; END IF;
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON chunk_embeddings USING hnsw ((embedding::vector(%s)) vector_cosine_ops) WHERE model_id = %L',
        'ix_emb_hnsw_' || replace(p_model_id::text, '-', '_'), d, p_model_id);
END
$$;

-- ----------------------------------------------------------------------------
-- Authentication helpers (SECURITY DEFINER: usable before tenant context exists)
-- ----------------------------------------------------------------------------

-- Look up an API key by its public prefix across tenants, so the request path
-- can establish (tenant_id, user_id) before any app.* GUC is set.
CREATE FUNCTION app_authenticate_api_key(p_prefix text)
    RETURNS TABLE (id uuid, tenant_id uuid, acts_as_user uuid, key_hash text,
                   scopes text[], collection_id uuid,
                   revoked_at timestamptz, expires_at timestamptz)
    LANGUAGE sql SECURITY DEFINER SET search_path = public AS
$$
    SELECT id, tenant_id, acts_as_user, key_hash, scopes, collection_id, revoked_at, expires_at
    FROM api_keys WHERE key_prefix = p_prefix
$$;

CREATE FUNCTION app_touch_api_key(p_id uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER SET search_path = public AS
$$ UPDATE api_keys SET last_used_at = now() WHERE id = p_id $$;

-- ----------------------------------------------------------------------------
-- Row-level security
-- ----------------------------------------------------------------------------

-- Generic parts for every tenant-owned table: enable + force, an owner bypass
-- (only reachable via SECURITY DEFINER functions), and full tenant access for
-- the worker. API policies are added per-table afterwards.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'users','teams','team_members','collections','collection_grants','api_keys',
        'documents','document_versions','ingestion_jobs','chunks','chunk_embeddings','audit_log'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY p_owner ON %I TO riptide_owner USING (true) WITH CHECK (true)', t);
        EXECUTE format(
            'CREATE POLICY p_worker ON %I FOR ALL TO riptide_worker '
            'USING (tenant_id = app_current_tenant()) WITH CHECK (tenant_id = app_current_tenant())', t);
    END LOOP;
END $$;

-- tenants (keyed by id, not tenant_id)
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY p_owner  ON tenants TO riptide_owner  USING (true) WITH CHECK (true);
CREATE POLICY p_worker ON tenants FOR SELECT TO riptide_worker USING (id = app_current_tenant());
CREATE POLICY p_api    ON tenants FOR SELECT TO riptide_api    USING (id = app_current_tenant());

-- API read policies ----------------------------------------------------------
CREATE POLICY p_api ON users FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant());

CREATE POLICY p_api ON teams FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant());

CREATE POLICY p_api ON team_members FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant());

CREATE POLICY p_api ON collections FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_collection_role(id) IS NOT NULL);

CREATE POLICY p_api ON collection_grants FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant() AND app_collection_role(collection_id) IS NOT NULL);

CREATE POLICY p_api ON api_keys FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND (acts_as_user = app_current_user_id() OR app_is_tenant_admin()));

-- Documents: visible only with a grant AND sufficient clearance (hides titles too).
CREATE POLICY p_api_select ON documents FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND app_collection_role(collection_id) IS NOT NULL
           AND app_current_clearance() >= classification);

-- Editors+ may create/update documents, but never above their own clearance.
CREATE POLICY p_api_insert ON documents FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant()
                AND app_collection_role(collection_id) IN ('editor','owner')
                AND app_current_clearance() >= classification);

CREATE POLICY p_api_update ON documents FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND app_collection_role(collection_id) IN ('editor','owner'))
    WITH CHECK (tenant_id = app_current_tenant()
                AND app_collection_role(collection_id) IN ('editor','owner')
                AND app_current_clearance() >= classification);

CREATE POLICY p_api_select ON document_versions FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND EXISTS (SELECT 1 FROM documents d
                       WHERE d.tenant_id = document_versions.tenant_id
                         AND d.id = document_versions.document_id));

CREATE POLICY p_api_insert ON document_versions FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant()
                AND EXISTS (SELECT 1 FROM documents d
                            WHERE d.tenant_id = document_versions.tenant_id
                              AND d.id = document_versions.document_id
                              AND app_collection_role(d.collection_id) IN ('editor','owner')));

CREATE POLICY p_api_update ON document_versions FOR UPDATE TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND EXISTS (SELECT 1 FROM documents d
                       WHERE d.tenant_id = document_versions.tenant_id
                         AND d.id = document_versions.document_id
                         AND app_collection_role(d.collection_id) IN ('editor','owner')));

CREATE POLICY p_api ON ingestion_jobs FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND EXISTS (SELECT 1 FROM document_versions dv
                       WHERE dv.tenant_id = ingestion_jobs.tenant_id
                         AND dv.id = ingestion_jobs.document_version_id));

-- Chunks: read-only, current only, permitted principal, sufficient clearance.
-- Filtering happens here, inside the query, before ranking.
CREATE POLICY p_api ON chunks FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND is_current
           AND app_current_clearance() >= classification
           AND (app_current_user_id() = ANY (allowed_user_ids)
                OR allowed_team_ids && app_user_team_ids()
                OR app_is_tenant_admin()));

-- Embeddings are visible only when their chunk is visible (search can't leak).
CREATE POLICY p_api ON chunk_embeddings FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant()
           AND EXISTS (SELECT 1 FROM chunks c
                       WHERE c.tenant_id = chunk_embeddings.tenant_id
                         AND c.id = chunk_embeddings.chunk_id));

-- Audit log: insert + read within tenant, never update/delete.
CREATE POLICY p_api_insert ON audit_log FOR INSERT TO riptide_api
    WITH CHECK (tenant_id = app_current_tenant());
CREATE POLICY p_api_select ON audit_log FOR SELECT TO riptide_api
    USING (tenant_id = app_current_tenant());

-- ----------------------------------------------------------------------------
-- Privileges (RLS confines rows; GRANT confines verbs)
-- ----------------------------------------------------------------------------

-- Request path: read widely, write narrowly.
GRANT SELECT ON tenants, users, teams, team_members, collections, collection_grants,
    api_keys, documents, document_versions, ingestion_jobs, chunks, chunk_embeddings,
    audit_log, embedding_models TO riptide_api;
GRANT INSERT, UPDATE ON documents, document_versions TO riptide_api;
GRANT INSERT ON audit_log TO riptide_api;

-- Ingestion path: full read/write within its tenant (audit stays append-only).
GRANT SELECT ON tenants TO riptide_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, teams, team_members, collections,
    collection_grants, api_keys, documents, document_versions, ingestion_jobs,
    chunks, chunk_embeddings TO riptide_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON embedding_models TO riptide_worker;
GRANT SELECT, INSERT ON audit_log TO riptide_worker;

-- Authentication helpers: restrict to the app roles.
REVOKE ALL ON FUNCTION app_authenticate_api_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_touch_api_key(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_authenticate_api_key(text) TO riptide_api, riptide_worker;
GRANT EXECUTE ON FUNCTION app_touch_api_key(uuid) TO riptide_api, riptide_worker;
GRANT EXECUTE ON FUNCTION create_embedding_index(uuid) TO riptide_worker;

