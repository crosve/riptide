-- Teardown for the initial schema. Drops the objects migration 0001 created.
-- Extensions and roles live in bootstrap.sql (superuser) and are left untouched;
-- riptide_owner (non-superuser) could not drop/recreate them anyway.
SET search_path = public;

DROP TABLE IF EXISTS
    audit_log,
    chunk_embeddings,
    chunks,
    ingestion_jobs,
    document_versions,
    documents,
    api_keys,
    collection_grants,
    collections,
    team_members,
    teams,
    users,
    embedding_models,
    tenants
CASCADE;

DROP FUNCTION IF EXISTS app_authenticate_api_key(text)        CASCADE;
DROP FUNCTION IF EXISTS app_touch_api_key(uuid)               CASCADE;
DROP FUNCTION IF EXISTS create_embedding_index(uuid)          CASCADE;
DROP FUNCTION IF EXISTS app_tg_validate_embedding()           CASCADE;
DROP FUNCTION IF EXISTS app_tg_model_immutable()              CASCADE;
DROP FUNCTION IF EXISTS app_tg_doc_classification_sync()      CASCADE;
DROP FUNCTION IF EXISTS app_tg_grant_sync()                   CASCADE;
DROP FUNCTION IF EXISTS app_sync_collection_acl(uuid)         CASCADE;
DROP FUNCTION IF EXISTS app_tg_chunk_acl_snapshot()           CASCADE;
DROP FUNCTION IF EXISTS app_collection_role(uuid)             CASCADE;
DROP FUNCTION IF EXISTS app_user_team_ids()                   CASCADE;
DROP FUNCTION IF EXISTS app_is_tenant_admin()                 CASCADE;
DROP FUNCTION IF EXISTS app_current_clearance()               CASCADE;
DROP FUNCTION IF EXISTS app_current_user_id()                 CASCADE;
DROP FUNCTION IF EXISTS app_current_tenant()                  CASCADE;
