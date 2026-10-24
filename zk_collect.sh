#!/usr/bin/env bash
# =============================================================================
#  pgBlitzAudit Collect v2.0  (bash)
#  Zero Knowledge PostgreSQL snapshot bundle — multi-database aware
#
# =============================================================================
#  PREREQUISITES
# =============================================================================
#
#  Required:
#    * PostgreSQL 12 or later
#    * A role with pg_monitor, pg_read_all_stats, or superuser privilege.
#      Minimum manual grants (if not using a superuser):
#        GRANT pg_read_all_stats TO <user>;
#        GRANT pg_monitor        TO <user>;
#    * track_counts = on  (PostgreSQL default; drives table + index statistics)
#
#  Optional but strongly recommended:
#    * pg_stat_statements — query-level CPU / I/O / WAL analysis:
#        1. postgresql.conf:  shared_preload_libraries = 'pg_stat_statements'
#        2. Restart PostgreSQL
#        3. Per database:     CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
#        Without this the stat_statements section is NULL in every snapshot.
#    * track_io_timing = on — break down I/O wait inside pg_stat_statements:
#        ALTER SYSTEM SET track_io_timing = on; SELECT pg_reload_conf();
#
# =============================================================================
#
#  Mirrors zk_collect.ps1 — same output format, same bundle structure.
#
#  Usage:
#    ./zk_collect.sh [OPTIONS]
#
#  Options:
#    --host HOST              PostgreSQL server hostname (default: localhost)
#    --port PORT              PostgreSQL port (default: 5432)
#    --database DATABASE      Collect one database only (default: all databases)
#    --user USER              PostgreSQL user (default: postgres)
#    --password PASSWORD      PostgreSQL password (or export PGPASSWORD)
#    --output-dir DIR         Output directory (default: zk_audit_PG<VER>_YYYYMMDD_HHMMSS)
#    --docker-container NAME  Run psql/pg_dump inside this Docker container
#    --no-schema-dump         Skip pg_dump --schema-only
#    --no-stat-dump           Skip pg_dump --statistics-only (PG18+)
#    -h, --help               Show this help
#
#  Examples:
#    # All databases (default)
#    ./zk_collect.sh --host localhost --port 5432 --user postgres
#
#    # Single database
#    ./zk_collect.sh --database mydb --user postgres
#
#    # Docker container — all databases
#    ./zk_collect.sh --docker-container my-postgres --user postgres
#
#    # Docker container — single database
#    ./zk_collect.sh --docker-container my-postgres --database mydb
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PG_HOST="localhost"
PG_PORT=5432
DATABASE=""           # empty = collect all connectable databases
PG_USER="postgres"
PG_PASSWORD=""
OUTPUT_DIR=""
DOCKER_CONTAINER=""
NO_SCHEMA_DUMP=0
NO_STAT_DUMP=0

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_step() { printf "  \033[36m%s\033[0m\n"       "$*"; }
_ok()   { printf "  \033[32mOK  %s\033[0m\n"   "$*"; }
_warn() { printf "  \033[33mWARN  %s\033[0m\n" "$*"; }
_err()  { printf "  \033[31mERR  %s\033[0m\n"  "$*" >&2; exit 1; }
_gray() { printf "  \033[90m%s\033[0m\n"        "$*"; }

usage() {
  sed -n '/^#  Usage:/,/^[^#]/p' "$0" | sed 's/^#  \{0,2\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)              PG_HOST="$2";          shift 2 ;;
    --port)              PG_PORT="$2";          shift 2 ;;
    --database)          DATABASE="$2";         shift 2 ;;
    --user)              PG_USER="$2";          shift 2 ;;
    --password)          PG_PASSWORD="$2";      shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";       shift 2 ;;
    --docker-container)  DOCKER_CONTAINER="$2"; shift 2 ;;
    --no-schema-dump)    NO_SCHEMA_DUMP=1;      shift ;;
    --no-stat-dump)      NO_STAT_DUMP=1;        shift ;;
    -h|--help)           usage ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Password / env setup
# ---------------------------------------------------------------------------
ORIG_PGPASSWORD="${PGPASSWORD:-}"
[[ -n "$PG_PASSWORD" ]] && export PGPASSWORD="$PG_PASSWORD"

# ---------------------------------------------------------------------------
# Helpers: psql (SQL file → file), psql_cmd (inline SQL → stdout), pg_dump
# ---------------------------------------------------------------------------

# _psql SQL_FILE OUT_FILE DATABASE
_psql() {
  local sql_file="$1"
  local out_file="$2"
  local db="$3"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$sql_file")-$$"
    local tmp_in="/tmp/zk_in_${leaf}"
    local tmp_out="/tmp/zk_out_${leaf}"

    docker cp "$sql_file" "${DOCKER_CONTAINER}:${tmp_in}" > /dev/null
    docker exec "$DOCKER_CONTAINER" \
      sh -c "psql -U \"$PG_USER\" -d \"$db\" -A -t -q -f \"$tmp_in\" > \"$tmp_out\" 2>&1"
    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_in" "$tmp_out" > /dev/null
  else
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
         -A -t -q -f "$sql_file" -o "$out_file" 2>&1 | head -20 || true
  fi
}

# _psql_cmd INLINE_SQL DATABASE  → stdout
_psql_cmd() {
  local sql="$1"
  local db="${2:-postgres}"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    docker exec "$DOCKER_CONTAINER" \
      psql -U "$PG_USER" -d "$db" -A -t -q -c "$sql" 2>/dev/null | tr -d '\r'
  else
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
         -A -t -q -c "$sql" 2>/dev/null | tr -d '\r'
  fi
}

# _pgdump OUT_FILE DATABASE [EXTRA_ARGS...]
_pgdump() {
  local out_file="$1"
  local db="$2"
  shift 2
  local extra_args=("$@")

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$out_file")-$$"
    local tmp_out="/tmp/zk_pgdump_${leaf}"
    local arg_str
    arg_str="$(printf ' %q' "${extra_args[@]}")"
    docker exec "$DOCKER_CONTAINER" \
      sh -c "pg_dump -U \"$PG_USER\" -d \"$db\" ${arg_str} > \"$tmp_out\" 2>&1"
    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_out" > /dev/null
  else
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
            "${extra_args[@]}" -f "$out_file" 2>&1 | head -20 || true
  fi
}

# Human-readable KB
_kb() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local sz
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    echo "$(( (sz + 512) / 1024 ))"
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Step 0: Detect PostgreSQL major version (before creating output dir)
# ---------------------------------------------------------------------------
_CONNECT_DB="${DATABASE:-postgres}"

PG_VER_NUM=""
PG_VER_NUM=$(_psql_cmd "SELECT current_setting('server_version_num')::int;" "$_CONNECT_DB" \
  2>/dev/null | tr -d '[:space:]') || PG_VER_NUM=""
PG_VER_NUM="${PG_VER_NUM:-0}"
PG_MAJOR=$(( PG_VER_NUM / 10000 ))

# ---------------------------------------------------------------------------
# Setup output directory (name includes PG major version)
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="zk_audit_PG${PG_MAJOR}_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf "\n"
printf "  \033[97mpgBlitzAudit Collect v2.0 (bash)\033[0m\n"
_gray "Output: $OUTPUT_DIR"
_gray "PostgreSQL major version: ${PG_MAJOR}"
printf "\n"

# ---------------------------------------------------------------------------
# SQL file paths
# ---------------------------------------------------------------------------
CATALOG_SQL="${SCRIPT_DIR}/zk_catalog_dump.sql"
STAT_SQL="${SCRIPT_DIR}/zk_stat_dump.sql"
[[ -f "$CATALOG_SQL" ]] || _warn "zk_catalog_dump.sql not found at: ${CATALOG_SQL}"
[[ -f "$STAT_SQL"    ]] || _warn "zk_stat_dump.sql not found at: ${STAT_SQL}"

# ---------------------------------------------------------------------------
# Step 1: Discover databases to collect
# ---------------------------------------------------------------------------
DB_DISCOVERY_SQL="SELECT datname FROM pg_database \
  WHERE datallowconn AND datname NOT IN ('template0','template1') \
  ORDER BY datname;"

declare -a DB_LIST

if [[ -n "$DATABASE" ]]; then
  DB_LIST=("$DATABASE")
  _gray "Single-database mode: ${DATABASE}"
else
  _step "Discovering databases..."
  mapfile -t DB_LIST < <(_psql_cmd "$DB_DISCOVERY_SQL" "$_CONNECT_DB" 2>/dev/null \
    | grep -v '^[[:space:]]*$' || true)

  if [[ ${#DB_LIST[@]} -eq 0 ]]; then
    _warn "No connectable databases found. Falling back to 'postgres'."
    DB_LIST=("postgres")
  fi
  _ok "Found ${#DB_LIST[@]} database(s): ${DB_LIST[*]}"
fi

# ---------------------------------------------------------------------------
# Step 2: Collect catalog + statistics per database
# ---------------------------------------------------------------------------
for db in "${DB_LIST[@]}"; do
  printf "\n"
  _step "━━━ Database: ${db} ━━━"

  if [[ -f "$CATALOG_SQL" ]]; then
    CATALOG_OUT="${OUTPUT_DIR}/catalog_db_${db}.json"
    _step "  Collecting catalog snapshot..."
    if _psql "$CATALOG_SQL" "$CATALOG_OUT" "$db"; then
      _ok "catalog_db_${db}.json  ($(_kb "$CATALOG_OUT") KB)"
    else
      _warn "catalog_db_${db}.json failed"
    fi
  fi

  if [[ -f "$STAT_SQL" ]]; then
    STAT_OUT="${OUTPUT_DIR}/stat_db_${db}.json"
    _step "  Collecting statistics snapshot..."
    if _psql "$STAT_SQL" "$STAT_OUT" "$db"; then
      _ok "stat_db_${db}.json  ($(_kb "$STAT_OUT") KB)"
    else
      _warn "stat_db_${db}.json failed"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Step 3: pg_dump --schema-only per database
# ---------------------------------------------------------------------------
if [[ "$NO_SCHEMA_DUMP" -eq 0 ]]; then
  printf "\n"
  for db in "${DB_LIST[@]}"; do
    _step "pg_dump --schema-only: ${db}..."
    SCHEMA_OUT="${OUTPUT_DIR}/schema_dump_${db}.sql"
    SCHEMA_ARGS=("--schema-only" "--no-password")
    [[ "$PG_MAJOR" -ge 18 ]] && SCHEMA_ARGS+=("--no-statistics")

    if _pgdump "$SCHEMA_OUT" "$db" "${SCHEMA_ARGS[@]}"; then
      _ok "schema_dump_${db}.sql  ($(_kb "$SCHEMA_OUT") KB)"
    else
      _warn "schema_dump_${db}.sql failed"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 4: pg_dump --statistics-only  (PG18+ only)
# ---------------------------------------------------------------------------
if [[ "$NO_STAT_DUMP" -eq 0 ]]; then
  printf "\n"
  for db in "${DB_LIST[@]}"; do
    STATS_OUT="${OUTPUT_DIR}/statistics_dump_${db}.sql"

    if [[ "$PG_MAJOR" -ge 18 ]]; then
      _step "pg_dump --statistics-only (PG18+): ${db}..."
      if _pgdump "$STATS_OUT" "$db" "--statistics-only" "--no-password"; then
        _ok "statistics_dump_${db}.sql  ($(_kb "$STATS_OUT") KB)"
      else
        _warn "statistics_dump_${db}.sql failed"
        echo "-- pg_dump --statistics-only failed for database: $db" > "$STATS_OUT"
      fi
    else
      _gray "Skipping pg_dump --statistics-only for ${db} (PG${PG_MAJOR} — requires PG18+)"
      cat > "$STATS_OUT" <<EOF
-- pg_dump --statistics-only requires PostgreSQL 18+.
-- Planner statistics are available in catalog_db_${db}.json (planner_stats section).
-- PostgreSQL major version detected: ${PG_MAJOR}
EOF
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 5: manifest.json
# ---------------------------------------------------------------------------
printf "\n"
_step "Writing manifest..."

PG_VERSION=""
PG_VERSION=$(_psql_cmd "SELECT version();" "$_CONNECT_DB" 2>/dev/null \
  | tr -d '\r\n') || PG_VERSION=""
# Escape for JSON
PG_VERSION_JSON="${PG_VERSION//\\/\\\\}"
PG_VERSION_JSON="${PG_VERSION_JSON//\"/\\\"}"

if [[ -n "$DOCKER_CONTAINER" ]]; then
  HOST_VAL="docker:${DOCKER_CONTAINER}"
else
  HOST_VAL="${PG_HOST}:${PG_PORT}"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build databases JSON array
DB_JSON_ARR="["
FIRST=1
for db in "${DB_LIST[@]}"; do
  [[ "$FIRST" -eq 0 ]] && DB_JSON_ARR+=","
  DB_JSON_ARR+="\"${db}\""
  FIRST=0
done
DB_JSON_ARR+="]"

# Build files array
FILES_JSON="["
FIRST=1
for f in "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.sql; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "manifest.json" ]] && continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  if date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ" &>/dev/null; then
    MTIME="$(date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ")"
  else
    MTIME="$GENERATED_AT"
  fi
  [[ "$FIRST" -eq 0 ]] && FILES_JSON+=","
  FILES_JSON+="{\"name\":\"${NAME}\",\"size_bytes\":${SZ},\"modified\":\"${MTIME}\"}"
  FIRST=0
done
FILES_JSON+="]"

cat > "${OUTPUT_DIR}/manifest.json" <<EOF
{
  "zk_audit_version": "2.0",
  "generated_at": "${GENERATED_AT}",
  "pg_version": "${PG_VERSION_JSON}",
  "pg_major": ${PG_MAJOR},
  "host": "${HOST_VAL}",
  "databases": ${DB_JSON_ARR},
  "files": ${FILES_JSON}
}
EOF
_ok "manifest.json"

# ---------------------------------------------------------------------------
# Restore PGPASSWORD
# ---------------------------------------------------------------------------
if [[ -n "$PG_PASSWORD" ]]; then
  if [[ -n "$ORIG_PGPASSWORD" ]]; then
    export PGPASSWORD="$ORIG_PGPASSWORD"
  else
    unset PGPASSWORD
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
printf "  \033[97mBundle ready: %s\033[0m\n" "$OUTPUT_DIR"
printf "  \033[90mDatabases collected: %s\033[0m\n" "${DB_LIST[*]}"
printf "\n"
for f in "$OUTPUT_DIR"/*; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  printf "  \033[90m    %-44s %8d KB\033[0m\n" "$NAME" "$(( (SZ + 512) / 1024 ))"
done
printf "\n"
