-- =============================================================================
--  ZK Catalog Dump  v1.1
--  Zero Knowledge schema/structure snapshot — no user data collected
--
-- =============================================================================
--  PREREQUISITES
-- =============================================================================
--
--  Required:
--    * PostgreSQL 12 or later
--    * Role with pg_monitor or pg_read_all_stats privilege (or superuser).
--      Minimum manual grants:
--        GRANT pg_monitor TO <user>;
--        -- or individually:
--        GRANT SELECT ON pg_stats       TO <user>;
--        GRANT SELECT ON pg_stat_archiver TO <user>;
--    * track_counts = on  (PostgreSQL default)
--
--  Optional:
--    * pg_stat_statements installed and activated — not used in catalog dump,
--      but required for zk_stat_dump.sql to capture query-level statistics.
--
-- =============================================================================
--
--  Covers every source queried by ultimate_report.sql:
--    databases (+ XID wraparound age), schemas, tables (+ relpages, relfrozenxid),
--    columns (+ alignment/length for padding analysis), indexes, constraints
--    (+ FK column refs for unindexed-FK detection), sequences, views, functions,
--    extensions, tablespaces, roles (password hash TYPE only), key settings,
--    planner column statistics (pg_stats), unindexed FK pre-computed list
--
--  Usage (called automatically by zk_collect.sh):
--    psql -U <user> -d <db> -A -t -q -f zk_catalog_dump.sql -o catalog_db_<db>.json
--
--  Output: single JSON document to stdout
--  PG compatibility: 12-18+
-- =============================================================================

\pset format unaligned
\pset tuples_only on
\pset pager off

WITH

-- ---------------------------------------------------------------------------
meta AS (
  SELECT json_build_object(
    'type',               'zk_catalog_dump',
    'version',            '1.1',
    'generated_at',       now(),
    'pg_version',         version(),
    'pg_version_num',     current_setting('server_version_num')::int,
    'database',           current_database(),
    'server_encoding',    pg_encoding_to_char(
                            (SELECT encoding FROM pg_database WHERE datname = current_database())),
    'block_size',         current_setting('block_size')::int,
    'autovacuum_freeze_max_age', current_setting('autovacuum_freeze_max_age')::bigint
  ) AS v
),

-- ---------------------------------------------------------------------------
-- databases: include XID wraparound age for v_wrap detection
databases AS (
  SELECT json_agg(json_build_object(
    'name',              datname,
    'owner',             pg_get_userbyid(datdba),
    'encoding',          pg_encoding_to_char(encoding),
    'collate',           datcollate,
    'ctype',             datctype,
    'size_bytes',        pg_database_size(datname),
    'connlimit',         datconnlimit,
    'is_template',       datistemplate,
    'allow_conn',        datallowconn,
    'datfrozenxid',      datfrozenxid::text,
    'xid_age',           age(datfrozenxid),
    'xid_age_pct',       round(100.0 * age(datfrozenxid)
                           / NULLIF(current_setting('autovacuum_freeze_max_age')::bigint, 0), 1)
  ) ORDER BY datname) AS v
  FROM pg_database
),

-- ---------------------------------------------------------------------------
schemas AS (
  SELECT json_agg(json_build_object(
    'name',  nspname,
    'owner', pg_get_userbyid(nspowner)
  ) ORDER BY nspname) AS v
  FROM pg_namespace
  WHERE nspname NOT LIKE 'pg_toast%'
    AND nspname NOT LIKE 'pg_temp%'
),

-- ---------------------------------------------------------------------------
extensions AS (
  SELECT json_agg(json_build_object(
    'name',         extname,
    'version',      extversion,
    'schema',       n.nspname,
    'relocatable',  extrelocatable
  ) ORDER BY extname) AS v
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
),

-- ---------------------------------------------------------------------------
tablespaces AS (
  SELECT json_agg(json_build_object(
    'name',       spcname,
    'owner',      pg_get_userbyid(spcowner),
    'location',   pg_tablespace_location(oid),
    'size_bytes', pg_tablespace_size(oid)
  ) ORDER BY spcname) AS v
  FROM pg_tablespace
),

-- ---------------------------------------------------------------------------
-- tables: include relpages + relfrozenxid (needed for bloat formula + wraparound)
tables AS (
  SELECT json_agg(json_build_object(
    'schema',          t.schemaname,
    'table',           t.tablename,
    'owner',           t.tableowner,
    'tablespace',      t.tablespace,
    'total_bytes',     pg_total_relation_size(t.schemaname || '.' || quote_ident(t.tablename)),
    'table_bytes',     pg_relation_size(t.schemaname || '.' || quote_ident(t.tablename)),
    'index_bytes',     pg_indexes_size(t.schemaname || '.' || quote_ident(t.tablename)),
    'toast_bytes',     COALESCE(
                         pg_total_relation_size(t.schemaname || '.' || quote_ident(t.tablename))
                         - pg_relation_size(t.schemaname || '.' || quote_ident(t.tablename))
                         - pg_indexes_size(t.schemaname || '.' || quote_ident(t.tablename)), 0),
    'row_estimate',    c.reltuples::bigint,
    'relpages',        c.relpages,
    'relallvisible',   c.relallvisible,
    'relfrozenxid',    c.relfrozenxid::text,
    'table_xid_age',   age(c.relfrozenxid),
    'relkind',         c.relkind::text,
    'relpersistence',  c.relpersistence::text,
    'relhastriggers',  c.relhastriggers,
    'relhasindex',     c.relhasindex,
    'fillfactor',      (SELECT (regexp_match(c.reloptions::text, 'fillfactor=(\d+)'))[1]::int)
  ) ORDER BY t.schemaname, t.tablename) AS v
  FROM pg_tables t
  JOIN pg_class c      ON c.relname = t.tablename
  JOIN pg_namespace n  ON n.oid = c.relnamespace AND n.nspname = t.schemaname
  WHERE t.schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
),

-- ---------------------------------------------------------------------------
-- columns: full type info + alignment/length for padding waste analysis
columns AS (
  SELECT json_agg(json_build_object(
    'schema',        n.nspname,
    'table',         c.relname,
    'column',        a.attname,
    'position',      a.attnum,
    'type_name',     t.typname,
    'type_category', t.typcategory::text,
    'attlen',        a.attlen,        -- -1 = variable length
    'attalign',      a.attalign::text, -- c=1B, s=2B, i=4B, d=8B
    'attstorage',    a.attstorage::text, -- p=plain, e=external, m=main, x=extended
    'attnotnull',    a.attnotnull,
    'attndims',      a.attndims,
    'atthasdef',     a.atthasdef,
    'attidentity',   a.attidentity::text,
    'attgenerated',  a.attgenerated::text,
    'atttypmod',     a.atttypmod,     -- type modifier (e.g. varchar(N))
    'type_len',      CASE a.attlen
                       WHEN -1 THEN 'variable'
                       ELSE a.attlen::text || 'B'
                     END,
    'align_bytes',   CASE a.attalign
                       WHEN 'c' THEN 1
                       WHEN 's' THEN 2
                       WHEN 'i' THEN 4
                       WHEN 'd' THEN 8
                       ELSE NULL
                     END
  ) ORDER BY n.nspname, c.relname, a.attnum) AS v
  FROM pg_attribute a
  JOIN pg_class c     ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_type t      ON t.oid = a.atttypid
  WHERE a.attnum > 0
    AND NOT a.attisdropped
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    AND c.relkind IN ('r', 'p')  -- regular tables and partitioned tables only
),

-- ---------------------------------------------------------------------------
indexes AS (
  SELECT json_agg(json_build_object(
    'schema',       schemaname,
    'table',        tablename,
    'index_name',   indexname,
    'tablespace',   tablespace,
    'index_def',    indexdef,
    'size_bytes',   pg_relation_size(schemaname || '.' || quote_ident(indexname)),
    'is_unique',    ix.indisunique,
    'is_primary',   ix.indisprimary,
    'is_exclusion', ix.indisexclusion,
    'is_valid',     ix.indisvalid,
    'is_ready',     ix.indisready,
    'num_cols',     array_length(ix.indkey, 1),
    'indkey',       ix.indkey::int2[]::text,  -- column positions (for dup detection)
    'indclass',     ix.indclass::int4[]::text,
    'indoption',    ix.indoption::int2[]::text,
    'has_exprs',    ix.indexprs IS NOT NULL,
    'has_pred',     ix.indpred IS NOT NULL
  ) ORDER BY schemaname, tablename, indexname) AS v
  FROM pg_indexes i
  JOIN pg_class c    ON c.relname = indexname
  JOIN pg_index ix   ON ix.indexrelid = c.oid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- constraints: include conkey (column positions) for unindexed FK detection
constraints AS (
  SELECT json_agg(json_build_object(
    'schema',        n.nspname,
    'table',         cl.relname,
    'name',          conname,
    'type',          CASE contype
                       WHEN 'p' THEN 'PRIMARY KEY'
                       WHEN 'u' THEN 'UNIQUE'
                       WHEN 'f' THEN 'FOREIGN KEY'
                       WHEN 'c' THEN 'CHECK'
                       WHEN 'x' THEN 'EXCLUSION'
                       WHEN 't' THEN 'TRIGGER'
                       ELSE contype::text END,
    'is_deferrable', condeferrable,
    'is_deferred',   condeferred,
    'is_validated',  convalidated,
    'conkey',        conkey::text,   -- local column positions
    'confkey',       confkey::text,  -- referenced column positions
    'num_cols',      array_length(conkey, 1),
    'fk_schema',     fn.nspname,
    'fk_table',      fc.relname
  ) ORDER BY n.nspname, cl.relname, conname) AS v
  FROM pg_constraint co
  JOIN pg_class     cl ON cl.oid = co.conrelid
  JOIN pg_namespace n  ON n.oid = cl.relnamespace
  LEFT JOIN pg_class     fc ON fc.oid = co.confrelid
  LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- unindexed_fks: pre-computed (mirrors v_fk_unindexed in ultimate_report)
unindexed_fks AS (
  SELECT json_agg(json_build_object(
    'schema',  n1.nspname,
    'table',   c1.relname,
    'column',  a1.attname,
    'fk_name', t.conname,
    'fk_refs', fn.nspname || '.' || fc.relname
  ) ORDER BY n1.nspname, c1.relname) AS v
  FROM pg_constraint t
  JOIN pg_attribute  a1 ON a1.attrelid = t.conrelid AND a1.attnum = t.conkey[1]
  JOIN pg_class      c1 ON c1.oid = t.conrelid
  JOIN pg_namespace  n1 ON n1.oid = c1.relnamespace
  LEFT JOIN pg_class     fc ON fc.oid = t.confrelid
  LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
  WHERE t.contype = 'f'
    AND n1.nspname NOT IN ('pg_catalog', 'information_schema')
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = t.conrelid
        AND i.indkey[0] = t.conkey[1]
    )
),

-- ---------------------------------------------------------------------------
sequences AS (
  SELECT json_agg(json_build_object(
    'schema',        n.nspname,
    'name',          c.relname,
    'data_type',     t.typname,
    'start',         s.seqstart,
    'increment',     s.seqincrement,
    'min',           s.seqmin,
    'max',           s.seqmax,
    'cache',         s.seqcache,
    'cycle',         s.seqcycle,
    'last_value',    ps.last_value,
    'exhausted_pct', CASE WHEN s.seqmax > s.seqmin
                       THEN round(100.0 * (
                         COALESCE(ps.last_value, s.seqmin) - s.seqmin
                       ) / NULLIF(s.seqmax - s.seqmin, 0), 2)
                     END
  ) ORDER BY n.nspname, c.relname) AS v
  FROM pg_sequence s
  JOIN pg_class c      ON c.oid = s.seqrelid
  JOIN pg_namespace n  ON n.oid = c.relnamespace
  JOIN pg_type t       ON t.oid = s.seqtypid
  LEFT JOIN pg_sequences ps ON ps.schemaname = n.nspname AND ps.sequencename = c.relname
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
views AS (
  SELECT json_agg(json_build_object(
    'schema',         table_schema,
    'name',           table_name,
    'is_updatable',   is_updatable = 'YES',
    'is_insertable',  is_insertable_into = 'YES'
  ) ORDER BY table_schema, table_name) AS v
  FROM information_schema.views
  WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
functions_summary AS (
  SELECT json_build_object(
    'total',     count(*),
    'languages', json_object_agg(lanname, cnt)
  ) AS v
  FROM (
    SELECT l.lanname, count(*) AS cnt
    FROM pg_proc p
    JOIN pg_language l  ON l.oid = p.prolang
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY l.lanname
  ) sub
),

-- ---------------------------------------------------------------------------
-- roles: include password hash TYPE (not value) for security audit
roles AS (
  SELECT json_agg(json_build_object(
    'name',         rolname,
    'superuser',    rolsuper,
    'inherit',      rolinherit,
    'createrole',   rolcreaterole,
    'createdb',     rolcreatedb,
    'login',        rolcanlogin,
    'replication',  rolreplication,
    'bypassrls',    rolbypassrls,
    'connlimit',    rolconnlimit,
    'valid_until',  rolvaliduntil,
    'has_password', rolpassword IS NOT NULL,
    'pwd_type',     CASE
                      WHEN rolpassword IS NULL       THEN 'NOPASSWORD'
                      WHEN rolpassword LIKE 'SCRAM%' THEN 'SCRAM-SHA-256'
                      WHEN rolpassword LIKE 'md5%'   THEN 'MD5_WEAK'
                      ELSE 'OTHER'
                    END,
    'risk_level',   CASE
                      WHEN rolsuper OR rolcreaterole OR rolreplication THEN 'HIGH'
                      WHEN rolpassword IS NULL AND rolcanlogin THEN 'CRITICAL'
                      ELSE 'OK'
                    END
  ) ORDER BY rolname) AS v
  FROM pg_roles
  WHERE rolname NOT LIKE 'pg_%'
),

-- ---------------------------------------------------------------------------
-- settings: complete set used by audit checks
settings_key AS (
  SELECT json_agg(json_build_object(
    'name',     name,
    'setting',  setting,
    'unit',     unit,
    'source',   source,
    'min_val',  min_val,
    'max_val',  max_val
  ) ORDER BY name) AS v
  FROM pg_settings
  WHERE name IN (
    'max_connections','shared_buffers','work_mem','maintenance_work_mem',
    'effective_cache_size','wal_level','max_wal_size','min_wal_size',
    'checkpoint_completion_target','checkpoint_timeout',
    'max_worker_processes','max_parallel_workers','max_parallel_workers_per_gather',
    'autovacuum','autovacuum_max_workers','autovacuum_vacuum_cost_delay',
    'autovacuum_freeze_max_age','vacuum_freeze_min_age','vacuum_freeze_table_age',
    'fsync','full_page_writes','synchronous_commit','wal_compression',
    'log_min_duration_statement','log_checkpoints','log_lock_waits',
    'random_page_cost','seq_page_cost','effective_io_concurrency',
    'jit','enable_partitionwise_join','enable_partitionwise_aggregate',
    'track_counts','track_io_timing','track_functions','pg_stat_statements.max',
    'default_statistics_target','constraint_exclusion','enable_bitmapscan',
    'password_encryption','block_size','wal_block_size',
    'ssl','ssl_min_protocol_version'
  )
),

-- ---------------------------------------------------------------------------
-- pg_stats: planner column statistics — used by bloat formula in ultimate_report
-- (null_frac, avg_width per column; NOT actual data values)
planner_stats AS (
  SELECT json_agg(json_build_object(
    'schema',        schemaname,
    'table',         tablename,
    'column',        attname,
    'inherited',     inherited,
    'null_frac',     round(null_frac::numeric, 4),
    'avg_width',     avg_width,
    'n_distinct',    n_distinct,
    'correlation',   round(correlation::numeric, 4),
    'most_common_freqs_count', array_length(most_common_freqs, 1),
    'histogram_bounds_count',  array_length(histogram_bounds, 1)
  ) ORDER BY schemaname, tablename, attname) AS v
  FROM pg_stats
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- bloat_pre_computed: same formula as v_bloat in ultimate_report.sql
bloat_computed AS (
  SELECT json_agg(json_build_object(
    'schema',      schemaname,
    'table',       tablename,
    'relpages',    relpages,
    'otta',        otta,
    'tbloat',      round((CASE WHEN otta = 0 THEN 0.0
                          ELSE relpages::float / NULLIF(otta, 0) END)::numeric, 1),
    'wasted_pages',GREATEST(relpages - otta, 0),
    'wasted_bytes', GREATEST(relpages - otta, 0) * current_setting('block_size')::int
  ) ORDER BY GREATEST(relpages - otta, 0) DESC NULLS LAST) AS v
  FROM (
    SELECT schemaname, tablename, cc.relpages,
      CEIL((cc.reltuples * 27.0) / NULLIF(current_setting('block_size')::int - 20, 0))::bigint AS otta
    FROM pg_stats s
    JOIN pg_class cc     ON cc.relname = s.tablename
    JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = s.schemaname
    WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY schemaname, tablename, cc.relpages, cc.reltuples
  ) foo
  WHERE relpages > otta
),

-- ---------------------------------------------------------------------------
-- available extensions (for extension audit)
available_extensions AS (
  SELECT json_agg(json_build_object(
    'name',              name,
    'default_version',   default_version,
    'installed_version', installed_version,
    'comment',           comment
  ) ORDER BY name) AS v
  FROM pg_available_extensions
  WHERE installed_version IS NOT NULL
     OR name IN ('pg_stat_statements','pg_buffercache','pgstattuple',
                 'auto_explain','pg_prewarm','timescaledb','postgis','pgvector')
),

-- ---------------------------------------------------------------------------
-- functions: per-function / procedure detail
functions AS (
  SELECT json_agg(json_build_object(
    'schema',           n.nspname,
    'name',             p.proname,
    'language',         l.lanname,
    'kind',             CASE p.prokind
                          WHEN 'f' THEN 'function'
                          WHEN 'p' THEN 'procedure'
                          WHEN 'a' THEN 'aggregate'
                          WHEN 'w' THEN 'window'
                          ELSE p.prokind::text END,
    'return_type',      CASE WHEN p.prokind = 'p' THEN NULL
                             ELSE pg_get_function_result(p.oid) END,
    'arguments',        pg_get_function_arguments(p.oid),
    'volatility',       CASE p.provolatile
                          WHEN 'i' THEN 'immutable'
                          WHEN 's' THEN 'stable'
                          WHEN 'v' THEN 'volatile' END,
    'security_definer', p.prosecdef,
    'strict',           p.proisstrict,
    'parallel',         CASE p.proparallel
                          WHEN 's' THEN 'safe'
                          WHEN 'r' THEN 'restricted'
                          WHEN 'u' THEN 'unsafe' END,
    'cost',             p.procost,
    'rows',             p.prorows,
    'definition',       CASE WHEN l.lanname NOT IN ('internal', 'c')
                               THEN pg_get_functiondef(p.oid)
                             ELSE NULL END
  ) ORDER BY n.nspname, p.proname, pg_get_function_arguments(p.oid)) AS v
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l  ON l.oid = p.prolang
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- triggers: per-trigger detail
triggers AS (
  SELECT json_agg(json_build_object(
    'schema',           n.nspname,
    'table',            c.relname,
    'trigger_name',     t.tgname,
    'enabled',          t.tgenabled <> 'D',
    'timing',           CASE
                          WHEN (t.tgtype &  2) <> 0 THEN 'BEFORE'
                          WHEN (t.tgtype & 64) <> 0 THEN 'INSTEAD OF'
                          ELSE 'AFTER' END,
    'events',           array_remove(ARRAY[
                          CASE WHEN (t.tgtype &  4) <> 0 THEN 'INSERT'   END,
                          CASE WHEN (t.tgtype &  8) <> 0 THEN 'DELETE'   END,
                          CASE WHEN (t.tgtype & 16) <> 0 THEN 'UPDATE'   END,
                          CASE WHEN (t.tgtype & 32) <> 0 THEN 'TRUNCATE' END
                        ], NULL),
    'orientation',      CASE WHEN (t.tgtype & 1) <> 0 THEN 'ROW' ELSE 'STATEMENT' END,
    'function_schema',  fn.nspname,
    'function_name',    p.proname,
    'condition',        pg_get_expr(t.tgqual, t.tgrelid)
  ) ORDER BY n.nspname, c.relname, t.tgname) AS v
  FROM pg_trigger t
  JOIN pg_class c       ON c.oid = t.tgrelid
  JOIN pg_namespace n   ON n.oid = c.relnamespace
  JOIN pg_proc p        ON p.oid = t.tgfoid
  JOIN pg_namespace fn  ON fn.oid = p.pronamespace
  WHERE NOT t.tgisinternal
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- mat_views: materialized views
mat_views AS (
  SELECT json_agg(json_build_object(
    'schema',       schemaname,
    'name',         matviewname,
    'owner',        matviewowner,
    'tablespace',   tablespace,
    'is_populated', ispopulated,
    'definition',   definition
  ) ORDER BY schemaname, matviewname) AS v
  FROM pg_matviews
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- policies: row-level security policies
policies AS (
  SELECT json_agg(json_build_object(
    'schema',       n.nspname,
    'table',        c.relname,
    'name',         p.polname,
    'permissive',   p.polpermissive,
    'roles',        CASE
                      WHEN p.polroles = '{0}'::oid[] THEN ARRAY['PUBLIC']
                      ELSE ARRAY(SELECT rolname FROM pg_roles r
                                 WHERE r.oid = ANY(p.polroles))
                    END,
    'cmd',          CASE p.polcmd
                      WHEN 'r' THEN 'SELECT'
                      WHEN 'a' THEN 'INSERT'
                      WHEN 'w' THEN 'UPDATE'
                      WHEN 'd' THEN 'DELETE'
                      WHEN '*' THEN 'ALL'
                    END,
    'qual',         pg_get_expr(p.polqual, p.polrelid),
    'with_check',   pg_get_expr(p.polwithcheck, p.polrelid),
    'rls_enabled',  c.relrowsecurity,
    'rls_forced',   c.relforcerowsecurity
  ) ORDER BY n.nspname, c.relname, p.polname) AS v
  FROM pg_policy p
  JOIN pg_class c     ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
-- rules: rewrite rules on tables/views (excluding default view return rules)
-- pg_rules only has schemaname/tablename/rulename/definition; event and
-- do_instead come from pg_rewrite (ev_type, is_instead).
rules AS (
  SELECT json_agg(json_build_object(
    'schema',     n.nspname,
    'table',      c.relname,
    'rule_name',  r.rulename,
    'event',      CASE r.ev_type
                    WHEN '1' THEN 'SELECT'
                    WHEN '2' THEN 'UPDATE'
                    WHEN '3' THEN 'INSERT'
                    WHEN '4' THEN 'DELETE'
                    ELSE r.ev_type::text END,
    'do_instead', r.is_instead,
    'definition', pg_get_ruledef(r.oid)
  ) ORDER BY n.nspname, c.relname, r.rulename) AS v
  FROM pg_rewrite r
  JOIN pg_class c     ON c.oid = r.ev_class
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND r.rulename <> '_RETURN'
)

-- ---------------------------------------------------------------------------
SELECT json_build_object(
  '_meta',               (SELECT v FROM meta),
  'databases',           (SELECT v FROM databases),
  'schemas',             (SELECT v FROM schemas),
  'extensions',          (SELECT v FROM extensions),
  'available_extensions',(SELECT v FROM available_extensions),
  'tablespaces',         (SELECT v FROM tablespaces),
  'tables',              (SELECT v FROM tables),
  'columns',             (SELECT v FROM columns),
  'indexes',             (SELECT v FROM indexes),
  'constraints',         (SELECT v FROM constraints),
  'unindexed_fks',       (SELECT v FROM unindexed_fks),
  'sequences',           (SELECT v FROM sequences),
  'views',               (SELECT v FROM views),
  'functions_summary',   (SELECT v FROM functions_summary),
  'roles',               (SELECT v FROM roles),
  'settings_key',        (SELECT v FROM settings_key),
  'planner_stats',       (SELECT v FROM planner_stats),
  'bloat_computed',      (SELECT v FROM bloat_computed),
  'functions',           (SELECT v FROM functions),
  'triggers',            (SELECT v FROM triggers),
  'mat_views',           (SELECT v FROM mat_views),
  'policies',            (SELECT v FROM policies),
  'rules',               (SELECT v FROM rules)
);
