# pgblitzaudit — Collection Guide

**Audience:** the DBA or system administrator running this on a client server.
**Time:** 10 to 20 minutes.
**What it does:** reads catalogue metadata and aggregate statistics from a
PostgreSQL cluster and writes them to a folder. It does not read table rows,
does not install anything, and does not need internet access.

You will end up with a folder to zip and send back. Reports are produced
off-site from that folder.

---

## 1. What you need before you start

| Requirement | Detail |
|---|---|
| Server access | A PostgreSQL role that can read statistics and catalogue data (step 2) |
| Client tools | `psql` and `pg_dump`, ideally the same major version as the server |
| Shell | Bash (Linux/macOS) or PowerShell 5.1+ (Windows) |
| Disk | A few hundred MB where the bundle is written |
| Network | Nothing outbound; only a connection to the database |
| Downtime | None. Every statement is a read |

`pg_dump` refuses to dump a server newer than itself. If the server is 17 and
your client is 16, point `PATH` at a 17 client or use `--docker-container`.

---

## 2. Create a read-only role

Run as a superuser. Replace the password.

```sql
CREATE ROLE blitz_ro LOGIN PASSWORD 'choose-a-password';

GRANT pg_read_all_stats, pg_read_all_settings TO blitz_ro;

-- for every database that should be assessed
\c appdb
GRANT CONNECT ON DATABASE appdb TO blitz_ro;
GRANT USAGE ON SCHEMA public TO blitz_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO blitz_ro;
```

`pg_read_all_stats` covers `pg_stat_*` and `pg_stat_statements`;
`pg_read_all_settings` covers `pg_settings`. No write privilege is needed
anywhere.

Drop it when finished:

```sql
DROP ROLE blitz_ro;
```

---

## 3. Run the collection

**Windows (PowerShell):**

```powershell
$env:PGPASSWORD = "choose-a-password"
.\zk_collect.ps1 -PgHost db.example.com -User blitz_ro
```

**Linux / macOS:**

```bash
PGPASSWORD='choose-a-password' ./zk_collect.sh --host db.example.com --user blitz_ro
```

**Database inside Docker on this machine:**

```bash
./zk_collect.sh --docker-container pg-prod --user postgres
```

**One database only:**

```bash
./zk_collect.sh --host db.example.com --user blitz_ro --database appdb
```

Every connectable database is collected by default, excluding `template0` and
`template1`.

### What you should see

```text
  pgBlitzAudit Collect v2.0

  Output: zk_audit_PG17_20261024_143022
  PostgreSQL major version: 17

  Discovering databases...
  OK  Found 3 database(s): appdb postgres reporting

  --- Database: appdb ---
    Collecting catalog snapshot...      OK  catalog_db_appdb.json  (12 KB)
    Collecting statistics snapshot...   OK  stat_db_appdb.json     (43 KB)
  ...
  Bundle ready: zk_audit_PG17_20261024_143022
```

Any `WARN` is a failed step. Read it before continuing.

---

## 4. Verify the bundle before sending

**Windows:**

```powershell
.\tests\battle-test.ps1 -Bundle .\zk_audit_PG17_20261024_143022
```

**Linux:**

```bash
bash tests/battle-test.sh zk_audit_PG17_20261024_143022
```

Must end `RESULT: PASSED`. If it fails, re-run once; if it fails again, send us
the output.

---

## 5. Package and return

**Windows:**

```powershell
Compress-Archive -Path .\zk_audit_PG17_20261024_143022 -DestinationPath .\bundle.zip
Get-FileHash .\bundle.zip -Algorithm SHA256
```

**Linux:**

```bash
zip -r bundle.zip zk_audit_PG17_20261024_143022
sha256sum bundle.zip
```

Send the zip and the hash, in two channels if your policy requires.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `FATAL: password authentication failed` | Wrong password, or `pg_hba.conf` does not allow this host | Check `pg_hba.conf`; the role needs a `host` line |
| `permission denied for relation pg_stat_activity` | Missing `pg_read_all_stats` | Re-run the grants |
| `aborting because of server version mismatch` | Client older than server | Use a matching `pg_dump`, or `--docker-container` |
| `stat_db_*.json` much smaller than expected | `pg_stat_statements` not installed or not loaded | `SHOW shared_preload_libraries;` — note it for us; the report still works |
| `catalog_db_*.json` under 1 KB | A query failed; the error is in the file | Send us the file |
| `psql: command not found` | Client not on `PATH` | Add the PostgreSQL `bin` directory |

---

## 7. What leaves your server

| Collected | Never collected |
|---|---|
| Schema, table, column, index, constraint definitions | Any table row |
| Sizes, row estimates, bloat estimates, autovacuum state | Any column value |
| Roles, role attributes, grants, membership | Passwords (`rolpassword` is never selected) |
| `postgresql.conf` settings and `pg_settings` | Connection strings or credentials |
| Replication slots, WAL and archiver status | WAL or archive contents |
| Normalised statement digests (`?` in place of literals) | Raw SQL text, query samples |
| Extensions, functions, views, triggers and their owners | Data files |

Bundles are plain UTF-8 JSON and SQL. Review them before sending — the collector
is published as source precisely so that you can.

---

## 8. Questions people ask

**Does this read my data?** No. Catalogue tables and aggregate counters only.
The schema dump is `pg_dump --schema-only`.

**Can I run it on a replica?** Yes, and it is preferable. Note in your message
that it was a replica — statistics describe it, not the primary.

**Does it need internet?** No.

**What if it fails halfway?** Delete the folder and re-run. Nothing is left
behind on the server.

**Where is the code?** `https://github.com/emerichunter/pgblitzaudit-collect`

---

## 9. Optional: operating system health

For CPU, memory, disk, I/O wait, kernel parameters and open ports:

```bash
./sys_collect.sh
```

Include its output folder in the zip.
