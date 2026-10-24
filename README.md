# pgBlitzAudit Collect

`pgBlitzAudit Collect` is a zero-knowledge PostgreSQL assessment collector: it captures the metadata and statistics an auditor needs without extracting application data.

## What it collects

- **Catalog metadata**: databases, schemas, tables, columns, indexes, constraints, unindexed foreign keys, sequences, views, materialized views, functions, triggers, policies, rules, extensions, tablespaces, roles, key settings, planner statistics, and bloat estimates.
- **Statistics**: `pg_stat_statements` aggregates (query text is normalized by PostgreSQL), table and index activity, `pg_stat_bgwriter`, `pg_stat_database`, replication, replication slots, activity summary, lock summary, blocking sessions, bloat estimates, duplicate/unused indexes, missing-index candidates, archiver status, and vacuum progress.
- **Schema DDL**: `pg_dump --schema-only` per database. On PostgreSQL 18+, a separate `pg_dump --statistics-only` output is also produced.
- **OS health** (`sys_collect.sh`): CPU, load, memory, huge pages, disk, I/O, mounts, kernel parameters, network interfaces and throughput, sockets, top processes, services, security posture, Docker stats, and kernel/OOM events.

It never collects table row data, query literals, password hashes, or connection strings. Role passwords are represented only by hash type (`SCRAM-SHA-256`, `MD5_WEAK`, `NOPASSWORD`, or `OTHER`); database targets are recorded as `host:port`, without credentials.

## Requirements

- PostgreSQL 12 or later.
- `psql` and `pg_dump` on the machine running the collector (or inside the Docker container when using the Docker option). Use a `pg_dump` version matching the server major version.
- Optional `pg_stat_statements`: unlocks query-level calls, latency, CPU, I/O, WAL, and planning statistics. Without it, the `stat_statements` section is `null` and the rest of the bundle is unaffected.
- Optional `track_io_timing`: adds I/O wait timing to `pg_stat_statements`. Without it, timing columns are zero or unavailable.
- `track_counts` stays at its PostgreSQL default (`on`) for table and index statistics.

## Quick start: Linux, macOS, WSL

```bash
export PGPASSWORD='...'
bash zk_collect.sh --host db.example.com --user audit_reader
```

The collector writes a new directory in the current directory. Use `--database appdb` for a single database, `--port` for a non-default port, or `--output-dir` to choose the destination. Run `bash zk_collect.sh --help` for all options.

## Quick start: Windows

```powershell
$env:PGPASSWORD = "..."
.\zk_collect.ps1 -PgHost db.example.com -User audit_reader
```

The Windows collector snapshots one database at a time (`-Database`, default `postgres`). Use `-OutputDir` to choose the destination and `-NoSchemaDump` or `-NoStatDump` to skip those steps.

## Docker

When PostgreSQL runs in a container, run the collector against that container so `psql` and `pg_dump` execute inside it:

```bash
bash zk_collect.sh --docker-container pg-prod --user postgres
```

```powershell
.\zk_collect.ps1 -DockerContainer pg-prod -User postgres
```

The container must provide `psql` and `pg_dump`; the official PostgreSQL images do.

## Required privileges

The collector needs monitoring access. As a superuser, grant these to a dedicated login role:

```sql
GRANT pg_read_all_stats TO audit_reader;
GRANT pg_monitor        TO audit_reader;
```

The role also needs `CONNECT` on each database it should inspect. Membership in `pg_monitor` includes `pg_read_all_stats`, but both grants are shown for clarity.

## What you get

The bash collector creates a bundle per run:

```text
zk_audit_PG17_20261024_143000/
  catalog_db_appdb.json
  stat_db_appdb.json
  schema_dump_appdb.sql
  statistics_dump_appdb.sql
  catalog_db_postgres.json
  stat_db_postgres.json
  schema_dump_postgres.sql
  statistics_dump_postgres.sql
  manifest.json
```

File naming is per database: `catalog_db_<database>.json`, `stat_db_<database>.json`, `schema_dump_<database>.sql`, and `statistics_dump_<database>.sql`. On PostgreSQL 17 and earlier, `statistics_dump_<database>.sql` contains a short explanatory note because `--statistics-only` requires PostgreSQL 18.

Expect roughly 250-400 KB per database, or about 700 KB-1.2 MB for three databases.

`manifest.json` contains:

```json
{
  "zk_audit_version": "2.0",
  "generated_at": "2026-10-24T14:30:00Z",
  "pg_version": "PostgreSQL 17.4 ...",
  "pg_major": 17,
  "host": "db.example.com:5432",
  "databases": ["appdb", "postgres"],
  "files": [
    {"name": "catalog_db_appdb.json", "size_bytes": 182344, "modified": "2026-10-24T14:30:01Z"}
  ]
}
```

The Windows collector uses `catalog_snapshot.json`, `stat_snapshot.json`, `schema_dump.sql`, and `statistics_dump.sql` for its single database. Its manifest carries the same version and file inventory fields, with `database` in place of `databases` and no `pg_major` field.

## What to do with the bundle

Zip the bundle directory and send it to your auditor or consultant:

```bash
zip -r zk_audit_PG17_20261024_143000.zip zk_audit_PG17_20261024_143000
```

Report generation happens off-site and needs no further access to the server.

## Version compatibility

PostgreSQL 12 through 18 are supported. The bash bundle name embeds the detected major version, for example `zk_audit_PG17_20261024_143000`, and `manifest.json` records the full server version. The Windows collector uses a `zk_audit_YYYYMMDD_HHMMSS` directory name and records the version in `manifest.json`.

## Troubleshooting

- **`pg_stat_statements` is not installed or not preloaded**: the `stat_statements` section comes back empty (`null`), not as an error. Enable it with `shared_preload_libraries = 'pg_stat_statements'`, restart PostgreSQL, then run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` in each database you collect.
- **Permission denied on a section**: sections the role cannot read degrade to `N/A` in the report instead of failing the run. Grant `pg_monitor` and `pg_read_all_stats` to reduce gaps.
- **`pg_dump: server version mismatch`**: install the client tools for the server major version, or run the collector inside the database container with `--docker-container`.
- **Nothing is collected**: verify the role can connect (`psql -h <host> -U <user> -d postgres`) and that `psql` and `pg_dump` are on `PATH`.

## License

MIT. See [LICENSE](LICENSE).

Issues and pull requests are welcome.
