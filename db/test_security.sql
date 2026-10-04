-- ============================================================================
-- riptide security tests. Run by run_tests.sh against a throwaway DB.
-- Seed runs as the connecting superuser (RLS bypassed); every assertion runs as
-- riptide_api / riptide_worker with app.tenant_id / app.user_id set, exactly as
-- the application does per request.
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off

-- Fixed ids so inserts and assertions can reference the same rows.
\set ta      aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
\set tb      bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
\set admin_a a0000000-0000-0000-0000-000000000001
\set alice   a0000000-0000-0000-0000-000000000002
\set bob     a0000000-0000-0000-0000-000000000003
\set carol   a0000000-0000-0000-0000-000000000004
\set dave    a0000000-0000-0000-0000-000000000005
\set eng     a1000000-0000-0000-0000-000000000001
\set col_pub ac000000-0000-0000-0000-000000000001
\set col_sec ac000000-0000-0000-0000-000000000002
\set doc1    ad000000-0000-0000-0000-000000000001
\set doc2    ad000000-0000-0000-0000-000000000002
\set doc3    ad000000-0000-0000-0000-000000000003
\set dv1     ae000000-0000-0000-0000-000000000001
\set dv2     ae000000-0000-0000-0000-000000000002
\set dv3     ae000000-0000-0000-0000-000000000003
\set c1      af000000-0000-0000-0000-000000000001
\set c2      af000000-0000-0000-0000-000000000002
\set c3      af000000-0000-0000-0000-000000000003
\set m1      e0000000-0000-0000-0000-000000000001
\set user_b  b0000000-0000-0000-0000-000000000001
\set col_b   bc000000-0000-0000-0000-000000000001
\set doc_b   bd000000-0000-0000-0000-000000000001
\set dvb     be000000-0000-0000-0000-000000000001
\set cb      bf000000-0000-0000-0000-000000000001

-- ----------------------------------------------------------------------------
-- Seed (as superuser)
-- ----------------------------------------------------------------------------
INSERT INTO tenants (id, name) VALUES (:'ta','Tenant A'), (:'tb','Tenant B');

INSERT INTO users (id, tenant_id, email, clearance_level, is_tenant_admin) VALUES
    (:'admin_a', :'ta', 'admin@a.test', 3, true),
    (:'alice',   :'ta', 'alice@a.test', 1, false),
    (:'bob',     :'ta', 'bob@a.test',   0, false),
    (:'carol',   :'ta', 'carol@a.test', 3, false),
    (:'dave',    :'ta', 'dave@a.test',  2, false),
    (:'user_b',  :'tb', 'eve@b.test',   3, true);

INSERT INTO teams (id, tenant_id, name) VALUES (:'eng', :'ta', 'Engineering');
INSERT INTO team_members (tenant_id, team_id, user_id) VALUES (:'ta', :'eng', :'alice');

INSERT INTO collections (id, tenant_id, name) VALUES
    (:'col_pub', :'ta', 'Public'),
    (:'col_sec', :'ta', 'Secret'),
    (:'col_b',   :'tb', 'B Collection');

-- Grants on col_pub: eng team (alice) + carol + dave(editor). col_sec: none (admin only).
INSERT INTO collection_grants (tenant_id, collection_id, team_id, role) VALUES
    (:'ta', :'col_pub', :'eng', 'viewer');
INSERT INTO collection_grants (tenant_id, collection_id, user_id, role) VALUES
    (:'ta', :'col_pub', :'carol', 'viewer'),
    (:'ta', :'col_pub', :'dave',  'editor');

INSERT INTO documents (id, tenant_id, collection_id, title, classification) VALUES
    (:'doc1', :'ta', :'col_pub', 'Public Doc',       0),
    (:'doc2', :'ta', :'col_pub', 'Confidential Doc', 2),
    (:'doc3', :'ta', :'col_sec', 'Secret Doc',       0),
    (:'doc_b',:'tb', :'col_b',   'B Doc',            0);

INSERT INTO document_versions (id, tenant_id, document_id, version_no, content_sha256, status) VALUES
    (:'dv1', :'ta', :'doc1', 1, 'sha1', 'indexed'),
    (:'dv2', :'ta', :'doc2', 1, 'sha2', 'indexed'),
    (:'dv3', :'ta', :'doc3', 1, 'sha3', 'indexed'),
    (:'dvb', :'tb', :'doc_b',1, 'shab', 'indexed');

-- Chunks: ACL snapshot + classification filled by the BEFORE INSERT trigger.
INSERT INTO chunks (id, tenant_id, document_version_id, document_id, collection_id, ordinal, content, content_sha256) VALUES
    (:'c1', :'ta', :'dv1', :'doc1', :'col_pub', 0, 'public hello world',            'h1'),
    (:'c2', :'ta', :'dv2', :'doc2', :'col_pub', 0, 'confidential secret plans',     'h2'),
    (:'c3', :'ta', :'dv3', :'doc3', :'col_sec', 0, 'secret in private collection',  'h3'),
    (:'cb', :'tb', :'dvb', :'doc_b',:'col_b',   0, 'tenant b private data',         'hb');

-- Default embedding model (3 dims to keep literals small) + a couple of vectors.
INSERT INTO embedding_models (id, name, dimensions, params, status, is_default) VALUES
    (:'m1', 'test-embed', 3, '{"model_version":"1","query_prefix":"q: "}', 'active', true);
INSERT INTO chunk_embeddings (tenant_id, chunk_id, model_id, embedding) VALUES
    (:'ta', :'c1', :'m1', '[0.1,0.2,0.3]'),
    (:'ta', :'c2', :'m1', '[0.4,0.5,0.6]');

-- ----------------------------------------------------------------------------
-- Test harness
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _results (seq serial, name text, passed boolean, detail text);
GRANT INSERT ON _results TO PUBLIC;
GRANT USAGE, SELECT ON SEQUENCE _results_seq_seq TO PUBLIC;

-- Helper to (re)establish request context.
\set as_api 'RESET ROLE;'

-- == T1: no tenant/user set -> fail closed ==================================
RESET ROLE;
SELECT set_config('app.tenant_id','',false);
SELECT set_config('app.user_id','',false);
SET ROLE riptide_api;
DO $$ DECLARE dc int; cc int; BEGIN
    SELECT count(*) INTO dc FROM documents; SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T1 no context -> zero rows (fail closed)', dc=0 AND cc=0, format('docs=%s chunks=%s', dc, cc));
END $$;
RESET ROLE;

-- == T2/T3: viewer via team sees only permitted, clearance-limited rows =====
SELECT set_config('app.tenant_id', :'ta', false);
SELECT set_config('app.user_id',   :'alice', false);
SET ROLE riptide_api;
DO $$ DECLARE dc int; cc int; d2 int; BEGIN
    SELECT count(*) INTO dc FROM documents;
    SELECT count(*) INTO cc FROM chunks;
    SELECT count(*) INTO d2 FROM documents WHERE title = 'Confidential Doc';
    INSERT INTO _results(name,passed,detail) VALUES
        ('T2 alice (eng viewer, clr1) sees only doc1', dc=1, format('docs=%s', dc)),
        ('T3 alice sees only chunk c1',                cc=1, format('chunks=%s', cc)),
        ('T8 clearance hides doc2 title from alice',   d2=0, format('conf docs visible=%s', d2));
END $$;
RESET ROLE;

-- == T4: user with no grant sees nothing ===================================
SELECT set_config('app.user_id', :'bob', false);
SET ROLE riptide_api;
DO $$ DECLARE dc int; cc int; BEGIN
    SELECT count(*) INTO dc FROM documents; SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T4 bob (no grant) sees nothing', dc=0 AND cc=0, format('docs=%s chunks=%s', dc, cc));
END $$;
RESET ROLE;

-- == T5/T6: direct viewer with high clearance sees both col_pub docs ========
SELECT set_config('app.user_id', :'carol', false);
SET ROLE riptide_api;
DO $$ DECLARE dc int; cc int; BEGIN
    SELECT count(*) INTO dc FROM documents; SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T5 carol (viewer, clr3) sees doc1+doc2',  dc=2, format('docs=%s', dc)),
        ('T6 carol sees chunk c1+c2 (not col_sec)', cc=2, format('chunks=%s', cc));
END $$;
RESET ROLE;

-- == T7: tenant admin is owner everywhere ==================================
SELECT set_config('app.user_id', :'admin_a', false);
SET ROLE riptide_api;
DO $$ DECLARE dc int; cc int; BEGIN
    SELECT count(*) INTO dc FROM documents; SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T7 admin sees all 3 docs / 3 chunks in tenant', dc=3 AND cc=3, format('docs=%s chunks=%s', dc, cc));
END $$;

-- == T9: cross-tenant reads are blocked ====================================
DO $$ DECLARE bc int; BEGIN
    SELECT count(*) INTO bc FROM chunks WHERE tenant_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
    INSERT INTO _results(name,passed,detail) VALUES
        ('T9 admin cannot read tenant B chunks', bc=0, format('B chunks visible=%s', bc));
END $$;
RESET ROLE;

-- == T10: cross-tenant write is blocked (worker scoped to A) ================
SELECT set_config('app.tenant_id', :'ta', false);
SET ROLE riptide_worker;
DO $$ BEGIN
    BEGIN
        INSERT INTO collections (id, tenant_id, name)
        VALUES (gen_random_uuid(), 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'sneaky');
        INSERT INTO _results(name,passed,detail) VALUES ('T10 cross-tenant write blocked', false, 'insert succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T10 cross-tenant write blocked', true, 'blocked: '||SQLERRM);
    END;
END $$;
RESET ROLE;

-- == T11: viewers cannot upload (documents insert needs editor+) ============
SELECT set_config('app.user_id', :'alice', false);
SET ROLE riptide_api;
DO $$ BEGIN
    BEGIN
        INSERT INTO documents (tenant_id, collection_id, title, classification)
        VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ac000000-0000-0000-0000-000000000001','viewer upload',0);
        INSERT INTO _results(name,passed,detail) VALUES ('T11 viewer cannot upload', false, 'insert succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T11 viewer cannot upload', true, 'blocked: '||SQLERRM);
    END;
END $$;
RESET ROLE;

-- == T12: editor can upload, but not above own clearance ===================
SELECT set_config('app.user_id', :'dave', false);
SET ROLE riptide_api;
DO $$ DECLARE ok boolean; BEGIN
    BEGIN
        INSERT INTO documents (tenant_id, collection_id, title, classification)
        VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ac000000-0000-0000-0000-000000000001','dave upload',1);
        INSERT INTO _results(name,passed,detail) VALUES ('T12a editor can upload (clr2, class1)', true, 'ok');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T12a editor can upload (clr2, class1)', false, 'blocked: '||SQLERRM);
    END;
    BEGIN
        INSERT INTO documents (tenant_id, collection_id, title, classification)
        VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ac000000-0000-0000-0000-000000000001','too secret',3);
        INSERT INTO _results(name,passed,detail) VALUES ('T12b cannot classify above own clearance', false, 'insert succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T12b cannot classify above own clearance', true, 'blocked: '||SQLERRM);
    END;
END $$;
RESET ROLE;

-- == T13: API role cannot modify chunks ====================================
SELECT set_config('app.user_id', :'admin_a', false);
SET ROLE riptide_api;
DO $$ BEGIN
    BEGIN
        UPDATE chunks SET content = 'tampered' WHERE id = 'af000000-0000-0000-0000-000000000001';
        INSERT INTO _results(name,passed,detail) VALUES ('T13 API cannot modify chunks', false, 'update succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T13 API cannot modify chunks', true, 'blocked: '||SQLERRM);
    END;
END $$;

-- == T14: API can append audit, never delete it ============================
DO $$ DECLARE ins_ok boolean := false; BEGIN
    BEGIN
        INSERT INTO audit_log (tenant_id, user_id, action) VALUES
            ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','a0000000-0000-0000-0000-000000000001','query');
        ins_ok := true;
    EXCEPTION WHEN others THEN ins_ok := false; END;
    INSERT INTO _results(name,passed,detail) VALUES ('T14a API can append to audit_log', ins_ok, '');
    BEGIN
        DELETE FROM audit_log;
        INSERT INTO _results(name,passed,detail) VALUES ('T14b API cannot delete audit rows', false, 'delete succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T14b API cannot delete audit rows', true, 'blocked: '||SQLERRM);
    END;
END $$;
RESET ROLE;

-- == T15/T16: granting and revoking access propagates to chunk ACLs =========
SELECT set_config('app.tenant_id', :'ta', false);
SET ROLE riptide_worker;
INSERT INTO collection_grants (tenant_id, collection_id, user_id, role)
    VALUES (:'ta', :'col_pub', :'bob', 'viewer');
RESET ROLE;
SELECT set_config('app.user_id', :'bob', false);
SET ROLE riptide_api;
DO $$ DECLARE cc int; BEGIN
    SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T15 granting access propagates to chunks (bob sees c1)', cc=1, format('bob chunks=%s', cc));
END $$;
RESET ROLE;
SET ROLE riptide_worker;
DELETE FROM collection_grants WHERE tenant_id = :'ta' AND collection_id = :'col_pub' AND user_id = :'bob';
RESET ROLE;
SET ROLE riptide_api;
DO $$ DECLARE cc int; BEGIN
    SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T16 revoking access propagates to chunks (bob sees 0)', cc=0, format('bob chunks=%s', cc));
END $$;
RESET ROLE;

-- == T17: reclassifying a document propagates to its chunks =================
SET ROLE riptide_worker;
UPDATE documents SET classification = 2 WHERE id = :'doc1';
RESET ROLE;
SELECT set_config('app.user_id', :'alice', false);
SET ROLE riptide_api;
DO $$ DECLARE cc int; cls int; BEGIN
    SELECT count(*) INTO cc FROM chunks;           -- alice clr1 now blocked from c1
    INSERT INTO _results(name,passed,detail) VALUES
        ('T17 reclassify propagates (alice loses c1)', cc=0, format('alice chunks=%s', cc));
END $$;
RESET ROLE;
-- revert
SET ROLE riptide_worker;
UPDATE documents SET classification = 0 WHERE id = :'doc1';
RESET ROLE;

-- == T18: superseded chunks are hidden =====================================
SET ROLE riptide_worker;
UPDATE chunks SET is_current = false WHERE id = :'c1';
RESET ROLE;
SET ROLE riptide_api;   -- still alice
DO $$ DECLARE cc int; BEGIN
    SELECT count(*) INTO cc FROM chunks;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T18 superseded chunk hidden (alice sees 0)', cc=0, format('alice chunks=%s', cc));
END $$;
RESET ROLE;
SET ROLE riptide_worker;
UPDATE chunks SET is_current = true WHERE id = :'c1';
RESET ROLE;

-- == T hybrid: keyword search never leaks ==================================
SELECT set_config('app.user_id', :'alice', false);
SET ROLE riptide_api;
DO $$ DECLARE a int; BEGIN
    SELECT count(*) INTO a FROM chunks WHERE tsv @@ websearch_to_tsquery('english','secret');
    INSERT INTO _results(name,passed,detail) VALUES
        ('T19 keyword search hides secret chunks from alice', a=0, format('matches=%s', a));
END $$;
RESET ROLE;
SELECT set_config('app.user_id', :'carol', false);
SET ROLE riptide_api;
DO $$ DECLARE a int; BEGIN
    SELECT count(*) INTO a FROM chunks WHERE tsv @@ websearch_to_tsquery('english','secret');
    INSERT INTO _results(name,passed,detail) VALUES  -- carol sees c2 (col_pub) but not c3 (col_sec)
        ('T20 keyword search returns only permitted matches (carol)', a=1, format('matches=%s', a));
END $$;
RESET ROLE;

-- == T21: embedding model settings are immutable ===========================
SET ROLE riptide_worker;
DO $$ BEGIN
    BEGIN
        UPDATE embedding_models SET params = '{"model_version":"2"}' WHERE id = 'e0000000-0000-0000-0000-000000000001';
        INSERT INTO _results(name,passed,detail) VALUES ('T21 model params immutable', false, 'update succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T21 model params immutable', true, 'blocked: '||SQLERRM);
    END;
END $$;

-- == T22: wrong-size vectors are rejected ==================================
SELECT set_config('app.tenant_id', :'ta', false);
DO $$ BEGIN
    BEGIN
        INSERT INTO chunk_embeddings (tenant_id, chunk_id, model_id, embedding)
        VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','af000000-0000-0000-0000-000000000003',
                'e0000000-0000-0000-0000-000000000001','[0.1,0.2]');
        INSERT INTO _results(name,passed,detail) VALUES ('T22 wrong-size vector rejected', false, 'insert succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T22 wrong-size vector rejected', true, 'blocked: '||SQLERRM);
    END;
END $$;

-- == T23: vectors for a retired model are rejected =========================
INSERT INTO embedding_models (id, name, dimensions, params, status)
    VALUES ('e0000000-0000-0000-0000-000000000002','old-embed',3,'{"model_version":"1"}','active');
UPDATE embedding_models SET status='retired' WHERE id='e0000000-0000-0000-0000-000000000002';
DO $$ BEGIN
    BEGIN
        INSERT INTO chunk_embeddings (tenant_id, chunk_id, model_id, embedding)
        VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','af000000-0000-0000-0000-000000000003',
                'e0000000-0000-0000-0000-000000000002','[0.1,0.2,0.3]');
        INSERT INTO _results(name,passed,detail) VALUES ('T23 retired-model vector rejected', false, 'insert succeeded!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T23 retired-model vector rejected', true, 'blocked: '||SQLERRM);
    END;
END $$;

-- == T24: exactly one default model ========================================
INSERT INTO embedding_models (id, name, dimensions, params, status, is_default)
    VALUES ('e0000000-0000-0000-0000-000000000003','second-embed',3,'{"model_version":"1"}','active',false);
DO $$ BEGIN
    BEGIN
        UPDATE embedding_models SET is_default = true WHERE id = 'e0000000-0000-0000-0000-000000000003';
        INSERT INTO _results(name,passed,detail) VALUES ('T24 only one default model', false, 'second default allowed!');
    EXCEPTION WHEN others THEN
        INSERT INTO _results(name,passed,detail) VALUES ('T24 only one default model', true, 'blocked: '||SQLERRM);
    END;
END $$;

-- == T25: full model switch, search still respects permissions =============
-- register (building) -> index -> backfill current chunks -> flip default -> retire old -> drop old vectors
INSERT INTO embedding_models (id, name, dimensions, params, status)
    VALUES ('e0000000-0000-0000-0000-000000000004','new-embed',3,'{"model_version":"2"}','building');
SELECT create_embedding_index('e0000000-0000-0000-0000-000000000004');
INSERT INTO chunk_embeddings (tenant_id, chunk_id, model_id, embedding)
    SELECT tenant_id, id, 'e0000000-0000-0000-0000-000000000004', '[0.9,0.8,0.7]'
    FROM chunks WHERE is_current;
UPDATE embedding_models SET status='active' WHERE id='e0000000-0000-0000-0000-000000000004';
UPDATE embedding_models SET is_default=false WHERE id='e0000000-0000-0000-0000-000000000001';
UPDATE embedding_models SET is_default=true  WHERE id='e0000000-0000-0000-0000-000000000004';
UPDATE embedding_models SET status='retired', is_default=false WHERE id='e0000000-0000-0000-0000-000000000001';
DELETE FROM chunk_embeddings WHERE model_id='e0000000-0000-0000-0000-000000000001';
RESET ROLE;
SELECT set_config('app.user_id', :'alice', false);
SET ROLE riptide_api;
DO $$ DECLARE vis int; dflt int; BEGIN
    -- alice may read new-model embeddings only for chunks she can see (c1)
    SELECT count(*) INTO vis FROM chunk_embeddings
        WHERE model_id = 'e0000000-0000-0000-0000-000000000004';
    SELECT count(*) INTO dflt FROM embedding_models WHERE is_default;
    INSERT INTO _results(name,passed,detail) VALUES
        ('T25a after switch, alice sees only her chunk''s vector', vis=1, format('visible vectors=%s', vis)),
        ('T25b exactly one default after switch',                 dflt=1, format('defaults=%s', dflt));
END $$;
RESET ROLE;

-- ----------------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------------
\echo ''
\echo '================= results ================='
SELECT lpad(seq::text,2) AS n,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result,
       name,
       detail
FROM _results ORDER BY seq;

DO $$
DECLARE n_fail int; n_total int;
BEGIN
    SELECT count(*) FILTER (WHERE NOT passed), count(*) INTO n_fail, n_total FROM _results;
    RAISE NOTICE '% of % tests passed', n_total - n_fail, n_total;
    IF n_fail > 0 THEN
        RAISE EXCEPTION '% test(s) FAILED', n_fail;
    END IF;
END $$;
