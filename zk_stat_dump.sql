-- =============================================================================
--  ZK Stat Dump  v1.0
--  Zero Knowledge statistics/activity snapshot — no user data collected
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
--        GRANT SELECT ON pg_stat_statements   TO <user>;  -- if installed
--        GRANT SELECT ON pg_stat_bgwriter      TO <user>;
--        GRANT SELECT ON pg_stat_replication   TO <user>;
--        GRANT SELECT ON pg_stat_archiver      TO <user>;
--        GRANT SELECT ON pg_stat_activity      TO <user>;
--    * track_counts = on  (PostgreSQL default — required for table/index stats)
--
--  Optional but strongly recommended:
--    * pg_stat_statements — query-level CPU / I/O / WAL analysis:
--        1. postgresql.conf:  shared_preload_libraries = 'pg_stat_statements'
--        2. Restart PostgreSQL
--        3. Per database:     CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
--        Without this the stat_statements section is NULL in the snapshot.
--    * track_io_timing = on — I/O wait breakdown in pg_stat_statements:
--        ALTER SYSTEM SET track_io_timing = on; SELECT pg_reload_conf();
--
-- =============================================================================
--
--  What it captures:
--    pg_stat_statements, pg_stat_all_tables, pg_statio_all_tables,
--    pg_stat_user_indexes, pg_stat_bgwriter, pg_stat_database,
--    pg_stat_replication, pg_replication_slots, pg_stat_activity (summary),
--    pg_locks (summary), autovacuum queue, bloat estimates
--
--  Usage (called automatically by zk_collect.sh):
--    psql -U <user> -d <db> -A -t -q -f zk_stat_dump.sql -o stat_db_<db>.json
--
--  Output: single JSON document to stdout
--  PG compatibility: 12-18+
-- =============================================================================

\pset format unaligned
\pset tuples_only on
\pset pager off

-- Version detection — gates stat_statements, bgwriter, progress_vacuum, stat_statements_info
-- has_pss: avoids parse-time errors when pg_stat_statements is not installed
-- (PostgreSQL resolves table names at parse time; CASE WHEN EXISTS is not enough)
SELECT
  (current_setting('server_version_num')::int / 10000) AS major_ver,
  (current_setting('server_version_num')::int >= 170000) AS is_pg17,
  (current_setting('server_version_num')::int >= 150000) AS is_pg15,
  (current_setting('server_version_num')::int >= 140000) AS is_pg14,
  (current_setting('server_version_num')::int >= 130000) AS is_pg13,
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pss
\gset

WITH

-- ---------------------------------------------------------------------------
meta AS (
  SELECT json_build_object(
    'type',              'zk_stat_dump',
    'version',           '1.3',
    'generated_at',      now(),
    'pg_version',        version(),
    'pg_version_num',    current_setting('server_version_num')::int,
    'database',          current_database(),
    'pg_uptime',         now() - pg_postmaster_start_time(),
    'stats_reset_global',(SELECT stats_reset FROM pg_stat_bgwriter),
    -- Cluster role: mirrors pg_is_in_recovery() used by v_repl in ultimate_report
    'is_in_recovery',    pg_is_in_recovery(),
    'cluster_role',      CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END,
    'current_wal_lsn',   pg_current_wal_lsn()::text
  ) AS v
),

-- ---------------------------------------------------------------------------
-- pg_stat_statements — 5 version branches (PG12 / PG13 / PG14 / PG15-16 / PG17+)
--   PG12: total_time/mean_time/stddev_time, blk_read_time, no plan/wal/jit
--   PG13: +exec suffix rename, +wal_records/wal_bytes, +plan/mean_plan_time/plans
--   PG14: +jit_functions/generation_time, +toplevel (basic JIT only)
--   PG15-16: +jit_inlining/optimization/emission_time (extended JIT)
--   PG17+: shared_blk_read_time + local/temp variants, +stats_since
-- Outer \if :has_pss guard prevents parse-time "relation does not exist" errors
-- when the extension is not loaded (CASE WHEN EXISTS is a runtime check only).
\if :has_pss
\if :is_pg17
-- PG17+: renamed block timing cols, local/temp timing, stats_since
stat_statements AS (
  SELECT json_agg(json_build_object(
    'queryid',               queryid,
    'query',                 query,
    'calls',                 calls,
    'total_exec_time',       round(total_exec_time::numeric, 2),
    'mean_exec_time',        round(mean_exec_time::numeric, 2),
    'stddev_exec_time',      round(stddev_exec_time::numeric, 2),
    'min_exec_time',         round(min_exec_time::numeric, 2),
    'max_exec_time',         round(max_exec_time::numeric, 2),
    'rows',                  rows,
    'shared_blks_hit',       shared_blks_hit,
    'shared_blks_read',      shared_blks_read,
    'shared_blks_dirtied',   shared_blks_dirtied,
    'shared_blks_written',   shared_blks_written,
    'local_blks_hit',        local_blks_hit,
    'local_blks_read',       local_blks_read,
    'local_blks_dirtied',    local_blks_dirtied,
    'local_blks_written',    local_blks_written,
    'temp_blks_read',        temp_blks_read,
    'temp_blks_written',     temp_blks_written,
    'shared_blk_read_time',  round(shared_blk_read_time::numeric, 2),
    'shared_blk_write_time', round(shared_blk_write_time::numeric, 2),
    'local_blk_read_time',   round(local_blk_read_time::numeric, 2),
    'local_blk_write_time',  round(local_blk_write_time::numeric, 2),
    'temp_blk_read_time',    round(temp_blk_read_time::numeric, 2),
    'temp_blk_write_time',   round(temp_blk_write_time::numeric, 2),
    'wal_records',           wal_records,
    'wal_bytes',             wal_bytes,
    'total_plan_time',       round(total_plan_time::numeric, 2),
    'mean_plan_time',        round(mean_plan_time::numeric, 2),
    'plans',                 plans,
    'jit_functions',         jit_functions,
    'jit_generation_time',   round(jit_generation_time::numeric, 2),
    'jit_inlining_time',     round(jit_inlining_time::numeric, 2),
    'jit_optimization_time', round(jit_optimization_time::numeric, 2),
    'jit_emission_time',     round(jit_emission_time::numeric, 2),
    'toplevel',              toplevel,
    'stats_since',           stats_since
  ) ORDER BY total_exec_time DESC) AS v
  FROM pg_stat_statements
),
\elif :is_pg15
-- PG15-16: exec suffix, blk_read_time (old name), WAL, plan, full JIT extended, toplevel
stat_statements AS (
  SELECT json_agg(json_build_object(
    'queryid',               queryid,
    'query',                 query,
    'calls',                 calls,
    'total_exec_time',       round(total_exec_time::numeric, 2),
    'mean_exec_time',        round(mean_exec_time::numeric, 2),
    'stddev_exec_time',      round(stddev_exec_time::numeric, 2),
    'min_exec_time',         round(min_exec_time::numeric, 2),
    'max_exec_time',         round(max_exec_time::numeric, 2),
    'rows',                  rows,
    'shared_blks_hit',       shared_blks_hit,
    'shared_blks_read',      shared_blks_read,
    'shared_blks_dirtied',   shared_blks_dirtied,
    'shared_blks_written',   shared_blks_written,
    'local_blks_hit',        local_blks_hit,
    'local_blks_read',       local_blks_read,
    'local_blks_dirtied',    local_blks_dirtied,
    'local_blks_written',    local_blks_written,
    'temp_blks_read',        temp_blks_read,
    'temp_blks_written',     temp_blks_written,
    'blk_read_time',         round(blk_read_time::numeric, 2),
    'blk_write_time',        round(blk_write_time::numeric, 2),
    'wal_records',           wal_records,
    'wal_bytes',             wal_bytes,
    'total_plan_time',       round(total_plan_time::numeric, 2),
    'mean_plan_time',        round(mean_plan_time::numeric, 2),
    'plans',                 plans,
    'jit_functions',         jit_functions,
    'jit_generation_time',   round(jit_generation_time::numeric, 2),
    'jit_inlining_time',     round(jit_inlining_time::numeric, 2),
    'jit_optimization_time', round(jit_optimization_time::numeric, 2),
    'jit_emission_time',     round(jit_emission_time::numeric, 2),
    'toplevel',              toplevel
  ) ORDER BY total_exec_time DESC) AS v
  FROM pg_stat_statements
),
\elif :is_pg14
-- PG14: exec suffix, blk_read_time, WAL, plan, basic JIT only, toplevel
stat_statements AS (
  SELECT json_agg(json_build_object(
    'queryid',             queryid,
    'query',               query,
    'calls',               calls,
    'total_exec_time',     round(total_exec_time::numeric, 2),
    'mean_exec_time',      round(mean_exec_time::numeric, 2),
    'stddev_exec_time',    round(stddev_exec_time::numeric, 2),
    'min_exec_time',       round(min_exec_time::numeric, 2),
    'max_exec_time',       round(max_exec_time::numeric, 2),
    'rows',                rows,
    'shared_blks_hit',     shared_blks_hit,
    'shared_blks_read',    shared_blks_read,
    'shared_blks_dirtied', shared_blks_dirtied,
    'shared_blks_written', shared_blks_written,
    'local_blks_hit',      local_blks_hit,
    'local_blks_read',     local_blks_read,
    'local_blks_dirtied',  local_blks_dirtied,
    'local_blks_written',  local_blks_written,
    'temp_blks_read',      temp_blks_read,
    'temp_blks_written',   temp_blks_written,
    'blk_read_time',       round(blk_read_time::numeric, 2),
    'blk_write_time',      round(blk_write_time::numeric, 2),
    'wal_records',         wal_records,
    'wal_bytes',           wal_bytes,
    'total_plan_time',     round(total_plan_time::numeric, 2),
    'mean_plan_time',      round(mean_plan_time::numeric, 2),
    'plans',               plans,
    'jit_functions',       jit_functions,
    'jit_generation_time', round(jit_generation_time::numeric, 2),
    'toplevel',            toplevel
  ) ORDER BY total_exec_time DESC) AS v
  FROM pg_stat_statements
),
\elif :is_pg13
-- PG13: exec suffix rename, WAL columns, plan/mean_plan_time/plans — no JIT, no toplevel
stat_statements AS (
  SELECT json_agg(json_build_object(
    'queryid',             queryid,
    'query',               query,
    'calls',               calls,
    'total_exec_time',     round(total_exec_time::numeric, 2),
    'mean_exec_time',      round(mean_exec_time::numeric, 2),
    'stddev_exec_time',    round(stddev_exec_time::numeric, 2),
    'min_exec_time',       round(min_exec_time::numeric, 2),
    'max_exec_time',       round(max_exec_time::numeric, 2),
    'rows',                rows,
    'shared_blks_hit',     shared_blks_hit,
    'shared_blks_read',    shared_blks_read,
    'shared_blks_dirtied', shared_blks_dirtied,
    'shared_blks_written', shared_blks_written,
    'local_blks_hit',      local_blks_hit,
    'local_blks_read',     local_blks_read,
    'local_blks_dirtied',  local_blks_dirtied,
    'local_blks_written',  local_blks_written,
    'temp_blks_read',      temp_blks_read,
    'temp_blks_written',   temp_blks_written,
    'blk_read_time',       round(blk_read_time::numeric, 2),
    'blk_write_time',      round(blk_write_time::numeric, 2),
    'wal_records',         wal_records,
    'wal_bytes',           wal_bytes,
    'total_plan_time',     round(total_plan_time::numeric, 2),
    'mean_plan_time',      round(mean_plan_time::numeric, 2),
    'plans',               plans
  ) ORDER BY total_exec_time DESC) AS v
  FROM pg_stat_statements
),
\else
-- PG12: old column names — total_time/mean_time/stddev_time, no plan/wal/jit
stat_statements AS (
  SELECT json_agg(json_build_object(
    'queryid',             queryid,
    'query',               query,
    'calls',               calls,
    'total_exec_time',     round(total_time::numeric, 2),
    'mean_exec_time',      round(mean_time::numeric, 2),
    'stddev_exec_time',    round(stddev_time::numeric, 2),
    'min_exec_time',       round(min_time::numeric, 2),
    'max_exec_time',       round(max_time::numeric, 2),
    'rows',                rows,
    'shared_blks_hit',     shared_blks_hit,
    'shared_blks_read',    shared_blks_read,
    'shared_blks_dirtied', shared_blks_dirtied,
    'shared_blks_written', shared_blks_written,
    'local_blks_hit',      local_blks_hit,
    'local_blks_read',     local_blks_read,
    'local_blks_dirtied',  local_blks_dirtied,
    'local_blks_written',  local_blks_written,
    'temp_blks_read',      temp_blks_read,
    'temp_blks_written',   temp_blks_written,
    'blk_read_time',       round(blk_read_time::numeric, 2),
    'blk_write_time',      round(blk_write_time::numeric, 2)
  ) ORDER BY total_time DESC) AS v
  FROM pg_stat_statements
),
\endif
\else
-- pg_stat_statements extension not installed
stat_statements AS (
  SELECT NULL::json AS v
),
\endif

-- ---------------------------------------------------------------------------
-- n_ins_since_vacuum added in PG13; use \if branch to avoid parse-time column error
\if :is_pg13
stat_tables AS (
  SELECT json_agg(json_build_object(
    'schema',              schemaname,
    'table',               relname,
    'seq_scan',            seq_scan,
    'seq_tup_read',        seq_tup_read,
    'idx_scan',            idx_scan,
    'idx_tup_fetch',       idx_tup_fetch,
    'n_tup_ins',           n_tup_ins,
    'n_tup_upd',           n_tup_upd,
    'n_tup_del',           n_tup_del,
    'n_tup_hot_upd',       n_tup_hot_upd,
    'n_live_tup',          n_live_tup,
    'n_dead_tup',          n_dead_tup,
    'n_mod_since_analyze', n_mod_since_analyze,
    'n_ins_since_vacuum',  n_ins_since_vacuum,
    'last_vacuum',         last_vacuum,
    'last_autovacuum',     last_autovacuum,
    'last_analyze',        last_analyze,
    'last_autoanalyze',    last_autoanalyze,
    'vacuum_count',        vacuum_count,
    'autovacuum_count',    autovacuum_count,
    'analyze_count',       analyze_count,
    'autoanalyze_count',   autoanalyze_count
  ) ORDER BY schemaname, relname) AS v
  FROM pg_stat_all_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),
\else
-- PG12: no n_ins_since_vacuum column
stat_tables AS (
  SELECT json_agg(json_build_object(
    'schema',              schemaname,
    'table',               relname,
    'seq_scan',            seq_scan,
    'seq_tup_read',        seq_tup_read,
    'idx_scan',            idx_scan,
    'idx_tup_fetch',       idx_tup_fetch,
    'n_tup_ins',           n_tup_ins,
    'n_tup_upd',           n_tup_upd,
    'n_tup_del',           n_tup_del,
    'n_tup_hot_upd',       n_tup_hot_upd,
    'n_live_tup',          n_live_tup,
    'n_dead_tup',          n_dead_tup,
    'n_mod_since_analyze', n_mod_since_analyze,
    'last_vacuum',         last_vacuum,
    'last_autovacuum',     last_autovacuum,
    'last_analyze',        last_analyze,
    'last_autoanalyze',    last_autoanalyze,
    'vacuum_count',        vacuum_count,
    'autovacuum_count',    autovacuum_count,
    'analyze_count',       analyze_count,
    'autoanalyze_count',   autoanalyze_count
  ) ORDER BY schemaname, relname) AS v
  FROM pg_stat_all_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),
\endif

-- ---------------------------------------------------------------------------
statio_tables AS (
  SELECT json_agg(json_build_object(
    'schema',            schemaname,
    'table',             relname,
    'heap_blks_read',    heap_blks_read,
    'heap_blks_hit',     heap_blks_hit,
    'idx_blks_read',     idx_blks_read,
    'idx_blks_hit',      idx_blks_hit,
    'toast_blks_read',   toast_blks_read,
    'toast_blks_hit',    toast_blks_hit,
    'tidx_blks_read',    tidx_blks_read,
    'tidx_blks_hit',     tidx_blks_hit,
    'cache_hit_ratio',   CASE WHEN (heap_blks_read + heap_blks_hit) > 0
                           THEN round(100.0 * heap_blks_hit / (heap_blks_read + heap_blks_hit), 2)
                         END
  ) ORDER BY schemaname, relname) AS v
  FROM pg_statio_all_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
stat_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',        schemaname,
    'table',         relname,
    'index',         indexrelname,
    'idx_scan',      idx_scan,
    'idx_tup_read',  idx_tup_read,
    'idx_tup_fetch', idx_tup_fetch,
    'size_bytes',    pg_relation_size(si.indexrelid),
    'is_unique',     ix.indisunique,
    'is_primary',    ix.indisprimary,
    'is_valid',      ix.indisvalid
  ) ORDER BY schemaname, relname, indexrelname) AS v
  FROM pg_stat_user_indexes si
  JOIN pg_index ix ON ix.indexrelid = si.indexrelid
),

-- ---------------------------------------------------------------------------
-- pg_stat_bgwriter: PG17 split bgwriter — checkpointer stats moved to
-- pg_stat_checkpointer. psql \if selects the right branch at parse time.
\if :is_pg17
stat_bgwriter AS (
  SELECT json_build_object(
    'pg17_split',          true,
    'buffers_clean',       b.buffers_clean,
    'maxwritten_clean',    b.maxwritten_clean,
    'buffers_alloc',       b.buffers_alloc,
    'stats_reset',         b.stats_reset,
    'checkpoints_timed',   c.num_timed,
    'checkpoints_req',     c.num_requested,
    'checkpoint_write_time', c.write_time,
    'checkpoint_sync_time',  c.sync_time,
    'buffers_checkpoint',  c.buffers_written,
    'checkpointer_reset',  c.stats_reset
  ) AS v
  FROM pg_stat_bgwriter b, pg_stat_checkpointer c
),
\else
stat_bgwriter AS (
  SELECT json_build_object(
    'pg17_split',          false,
    'checkpoints_timed',   checkpoints_timed,
    'checkpoints_req',     checkpoints_req,
    'checkpoint_write_time', checkpoint_write_time,
    'checkpoint_sync_time',  checkpoint_sync_time,
    'buffers_checkpoint',  buffers_checkpoint,
    'buffers_clean',       buffers_clean,
    'maxwritten_clean',    maxwritten_clean,
    'buffers_backend',     buffers_backend,
    'buffers_backend_fsync', buffers_backend_fsync,
    'buffers_alloc',       buffers_alloc,
    'stats_reset',         stats_reset,
    'checkpoint_req_ratio', CASE WHEN (checkpoints_timed + checkpoints_req) > 0
      THEN round(100.0 * checkpoints_req / (checkpoints_timed + checkpoints_req), 2)
    END
  ) AS v
  FROM pg_stat_bgwriter
),
\endif

-- ---------------------------------------------------------------------------
stat_database AS (
  SELECT json_agg(json_build_object(
    'datname',         datname,
    'numbackends',     numbackends,
    'xact_commit',     xact_commit,
    'xact_rollback',   xact_rollback,
    'blks_read',       blks_read,
    'blks_hit',        blks_hit,
    'cache_hit_ratio', CASE WHEN (blks_read + blks_hit) > 0
                         THEN round(100.0 * blks_hit / (blks_read + blks_hit), 2)
                       END,
    'tup_returned',    tup_returned,
    'tup_fetched',     tup_fetched,
    'tup_inserted',    tup_inserted,
    'tup_updated',     tup_updated,
    'tup_deleted',     tup_deleted,
    'conflicts',       conflicts,
    'temp_files',      temp_files,
    'temp_bytes',      temp_bytes,
    'deadlocks',       deadlocks,
    'checksum_failures', checksum_failures,
    'blk_read_time',   round(blk_read_time::numeric, 2),
    'blk_write_time',  round(blk_write_time::numeric, 2),
    'stats_reset',     stats_reset
  ) ORDER BY datname) AS v
  FROM pg_stat_database
),

-- ---------------------------------------------------------------------------
stat_replication AS (
  SELECT json_agg(json_build_object(
    'application_name', application_name,
    'client_addr',     client_addr,
    'state',           state,
    'sent_lsn',        sent_lsn,
    'write_lsn',       write_lsn,
    'flush_lsn',       flush_lsn,
    'replay_lsn',      replay_lsn,
    'write_lag',       write_lag,
    'flush_lag',       flush_lag,
    'replay_lag',      replay_lag,
    'sync_state',      sync_state,
    'backend_start',   backend_start
  ) ORDER BY client_addr) AS v
  FROM pg_stat_replication
),

-- ---------------------------------------------------------------------------
replication_slots AS (
  SELECT json_agg(json_build_object(
    'slot_name',      slot_name,
    'plugin',         plugin,
    'slot_type',      slot_type,
    'database',       database,
    'active',         active,
    'active_pid',     active_pid,
    'xmin',           xmin,
    'catalog_xmin',   catalog_xmin,
    'restart_lsn',    restart_lsn,
    'confirmed_flush_lsn', confirmed_flush_lsn,
    'wal_lag_bytes',  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn),
    'temporary',      temporary
  ) ORDER BY slot_name) AS v
  FROM pg_replication_slots
),

-- ---------------------------------------------------------------------------
-- Activity summary — NO query text, just session counts by state
activity_summary AS (
  SELECT json_build_object(
    'total_connections',  count(*),
    'active',             count(*) FILTER (WHERE state = 'active'),
    'idle',               count(*) FILTER (WHERE state = 'idle'),
    'idle_in_transaction',count(*) FILTER (WHERE state = 'idle in transaction'),
    'waiting_on_lock',    count(*) FILTER (WHERE wait_event_type = 'Lock'),
    'oldest_xact_sec',    round(extract(epoch FROM max(now() - xact_start))::numeric, 1),
    'oldest_client_sec',  round(extract(epoch FROM max(now() - state_change))::numeric, 1),
    'max_idle_in_tx_sec', round(extract(epoch FROM max(
                            CASE WHEN state = 'idle in transaction' THEN now() - state_change END
                          ))::numeric, 1),
    'by_application',     (
                            SELECT json_object_agg(app, cnt)
                            FROM (
                              SELECT COALESCE(application_name, '<unknown>') AS app, count(*) AS cnt
                              FROM pg_stat_activity
                              WHERE pid != pg_backend_pid()
                              GROUP BY application_name
                            ) sub
                          )
  ) AS v
  FROM pg_stat_activity
  WHERE pid != pg_backend_pid()
),

-- ---------------------------------------------------------------------------
locks_summary AS (
  SELECT json_build_object(
    'total',   total,
    'granted', granted,
    'waiting', waiting,
    'by_type', by_type,
    'by_mode', by_mode
  ) AS v
  FROM (
    SELECT
      count(*)                              AS total,
      count(*) FILTER (WHERE granted)       AS granted,
      count(*) FILTER (WHERE NOT granted)   AS waiting,
      (SELECT json_object_agg(locktype, cnt)
       FROM (SELECT locktype, count(*) AS cnt FROM pg_locks GROUP BY locktype) t) AS by_type,
      (SELECT json_object_agg(mode, cnt)
       FROM (SELECT mode, count(*) AS cnt FROM pg_locks GROUP BY mode) m) AS by_mode
    FROM pg_locks
  ) sub
),

-- ---------------------------------------------------------------------------
-- Bloat estimate using pgstattuple approximation via catalog heuristics
-- (no actual table scan — purely statistical)
bloat_estimate AS (
  SELECT json_agg(json_build_object(
    'schema',         schemaname,
    'table',          relname,
    'n_live_tup',     n_live_tup,
    'n_dead_tup',     n_dead_tup,
    'dead_ratio',     CASE WHEN (n_live_tup + n_dead_tup) > 0
                        THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2)
                      END,
    'last_vacuum',    last_vacuum,
    'last_autovacuum',last_autovacuum
  ) ORDER BY n_dead_tup DESC NULLS LAST) AS v
  FROM pg_stat_user_tables
  WHERE (n_live_tup + n_dead_tup) > 0
),

-- ---------------------------------------------------------------------------
-- Duplicate index candidates (same table + same columns)
dup_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',     schema,
    'table',      tbl,
    'index_cols', index_cols,
    'indexes',    index_names
  ) ORDER BY schema, tbl) AS v
  FROM (
    SELECT
      n.nspname                                    AS schema,
      c.relname                                    AS tbl,
      array_to_string(ix.indkey::int2[], ',')      AS index_cols,
      json_agg(i.relname ORDER BY i.relname)       AS index_names
    FROM pg_index ix
    JOIN pg_class i  ON i.oid = ix.indexrelid
    JOIN pg_class c  ON c.oid = ix.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY n.nspname, c.relname, ix.indkey::int2[]
    HAVING count(*) > 1
  ) sub
),

-- ---------------------------------------------------------------------------
-- Unused indexes (zero scans since last stats reset)
unused_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',      schemaname,
    'table',       relname,
    'index',       indexrelname,
    'size_bytes',  pg_relation_size(si.indexrelid),
    'idx_scan',    idx_scan,
    'is_primary',  ix.indisprimary,
    'is_unique',   ix.indisunique
  ) ORDER BY pg_relation_size(si.indexrelid) DESC) AS v
  FROM pg_stat_user_indexes si
  JOIN pg_index ix ON ix.indexrelid = si.indexrelid
  WHERE idx_scan = 0
    AND NOT ix.indisprimary
    AND NOT ix.indisunique
),

-- ---------------------------------------------------------------------------
-- Missing index candidates (high seq_scan on large tables)
missing_index_candidates AS (
  SELECT json_agg(json_build_object(
    'schema',     schemaname,
    'table',      relname,
    'seq_scan',   seq_scan,
    'n_live_tup', n_live_tup,
    'size_bytes', pg_total_relation_size(schemaname || '.' || quote_ident(relname))
  ) ORDER BY seq_scan DESC) AS v
  FROM pg_stat_user_tables
  WHERE seq_scan > 100
    AND n_live_tup > 10000
    AND (idx_scan IS NULL OR seq_scan > idx_scan)
),

-- ---------------------------------------------------------------------------
-- WAL archiver status (mirrored from v_archiver in ultimate_report)
stat_archiver AS (
  SELECT CASE
    WHEN has_table_privilege('pg_stat_archiver', 'select')
    THEN (
      SELECT row_to_json(a) FROM (
        SELECT
          archived_count,
          last_archived_wal,
          last_archived_time,
          failed_count,
          last_failed_wal,
          last_failed_time,
          stats_reset,
          CASE
            WHEN archived_count IS NULL THEN 'ARCHIVING_DISABLED'
            WHEN failed_count > 0       THEN 'FAILURES'
            ELSE 'OK'
          END AS status
        FROM pg_stat_archiver
      ) a
    )
    ELSE json_build_object('status', 'PERMISSION_DENIED')
  END AS v
),

-- ---------------------------------------------------------------------------
-- User function execution stats
stat_user_functions AS (
  SELECT json_agg(json_build_object(
    'schema',      schemaname,
    'funcname',    funcname,
    'calls',       calls,
    'total_time',  round(total_time::numeric, 2),
    'self_time',   round(self_time::numeric, 2),
    'mean_time',   CASE WHEN calls > 0 THEN round(total_time::numeric / calls, 2) END
  ) ORDER BY total_time DESC NULLS LAST) AS v
  FROM pg_stat_user_functions
),

-- ---------------------------------------------------------------------------
-- Active vacuum / analyze progress (in-flight operations)
-- PG17+: indexes_total / indexes_processed added; max_dead_tuple_bytes renamed
-- PG12-16: max_dead_tuples / num_dead_tuples (old names)
\if :is_pg17
stat_progress_vacuum AS (
  SELECT json_agg(json_build_object(
    'pid',                 pid,
    'datname',             datname,
    'relid',               relid,
    'phase',               phase,
    'heap_blks_total',     heap_blks_total,
    'heap_blks_scanned',   heap_blks_scanned,
    'heap_blks_vacuumed',  heap_blks_vacuumed,
    'index_vacuum_count',  index_vacuum_count,
    'indexes_total',       indexes_total,
    'indexes_processed',   indexes_processed
  ) ORDER BY pid) AS v
  FROM pg_stat_progress_vacuum
),
\else
stat_progress_vacuum AS (
  SELECT json_agg(json_build_object(
    'pid',                 pid,
    'datname',             datname,
    'relid',               relid,
    'phase',               phase,
    'heap_blks_total',     heap_blks_total,
    'heap_blks_scanned',   heap_blks_scanned,
    'heap_blks_vacuumed',  heap_blks_vacuumed,
    'index_vacuum_count',  index_vacuum_count,
    'max_dead_tuples',     max_dead_tuples,
    'num_dead_tuples',     num_dead_tuples
  ) ORDER BY pid) AS v
  FROM pg_stat_progress_vacuum
),
\endif

-- ---------------------------------------------------------------------------
-- Blocking session detail (mirrors v_locks in ultimate_report)
blocking_sessions AS (
  SELECT json_agg(json_build_object(
    'pid',             pid,
    'usename',         usename,
    'backend_type',    backend_type,
    'blockers',        pg_blocking_pids(pid)::text,
    'wait_event_type', wait_event_type,
    'wait_event',      wait_event,
    'state',           state,
    'wait_secs',       extract(epoch FROM (now() - query_start))::int,
    'xact_age_secs',   extract(epoch FROM (now() - xact_start))::int,
    'query_snippet',   substring(query, 1, 200)
  ) ORDER BY pid) AS v
  FROM pg_stat_activity
  WHERE pg_blocking_pids(pid) <> '{}'
     OR (state = 'idle in transaction'
         AND (now() - xact_start) > interval '5 minutes')
),

-- ---------------------------------------------------------------------------
-- pg_stat_statements_info — PG14+, extension must be loaded
-- pg_stat_statements_info only exists on PG14+ when pg_stat_statements is installed.
\if :is_pg14
\if :has_pss
stat_statements_info AS (
  SELECT row_to_json(i) AS v
  FROM (SELECT dealloc, stats_reset FROM pg_stat_statements_info) i
)
\else
stat_statements_info AS (
  SELECT NULL::json AS v
)
\endif
\else
stat_statements_info AS (
  SELECT NULL::json AS v
)
\endif

-- ---------------------------------------------------------------------------
SELECT json_build_object(
  '_meta',                    (SELECT v FROM meta),
  'stat_statements',          (SELECT v FROM stat_statements),
  'stat_statements_info',     (SELECT v FROM stat_statements_info),
  'stat_tables',              (SELECT v FROM stat_tables),
  'statio_tables',            (SELECT v FROM statio_tables),
  'stat_indexes',             (SELECT v FROM stat_indexes),
  'stat_bgwriter',            (SELECT v FROM stat_bgwriter),
  'stat_database',            (SELECT v FROM stat_database),
  'stat_replication',         (SELECT v FROM stat_replication),
  'replication_slots',        (SELECT v FROM replication_slots),
  'activity_summary',         (SELECT v FROM activity_summary),
  'locks_summary',            (SELECT v FROM locks_summary),
  'blocking_sessions',        (SELECT v FROM blocking_sessions),
  'bloat_estimate',           (SELECT v FROM bloat_estimate),
  'dup_indexes',              (SELECT v FROM dup_indexes),
  'unused_indexes',           (SELECT v FROM unused_indexes),
  'missing_index_candidates', (SELECT v FROM missing_index_candidates),
  'stat_archiver',            (SELECT v FROM stat_archiver),
  'stat_user_functions',      (SELECT v FROM stat_user_functions),
  'stat_progress_vacuum',     (SELECT v FROM stat_progress_vacuum)
);
