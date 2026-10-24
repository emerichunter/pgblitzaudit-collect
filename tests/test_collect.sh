#!/usr/bin/env bash
# Smoke test for zk_collect.sh.
#
# Default: start postgres:17 in Docker, seed a tiny schema, collect, and assert.
# CI:      set PBA_TEST_DSN=postgresql://user:pass@host:port/db to use an
#          already-running server instead of starting a container.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="${REPO_DIR}/zk_collect.sh"

TMP_DIR="$(mktemp -d)"
CONTAINER=""
FAILS=0
CHECKS=0

cleanup() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILS=$((FAILS + 1))
  printf 'FAIL  %s\n' "$1"
}

finish() {
  printf '\n%d checks, %d failed\n' "$CHECKS" "$FAILS"
  if (( FAILS > 0 )); then
    exit 1
  fi
  printf 'PASS  all smoke checks\n'
}

free_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

seed_sql() {
  printf '%s\n' \
    'DROP TABLE IF EXISTS pba_order, pba_customer CASCADE;' \
    'CREATE TABLE pba_customer (' \
    '  id bigint PRIMARY KEY,' \
    '  email text NOT NULL,' \
    '  created_at timestamptz NOT NULL DEFAULT now()' \
    ');' \
    'CREATE TABLE pba_order (' \
    '  id bigint PRIMARY KEY,' \
    '  customer_id bigint NOT NULL REFERENCES pba_customer(id),' \
    '  total numeric(12,2) NOT NULL,' \
    '  created_at timestamptz NOT NULL DEFAULT now()' \
    ');' \
    'CREATE INDEX pba_order_customer_id_idx ON pba_order (customer_id);' \
    "INSERT INTO pba_customer (id, email) VALUES (1, 'a@example.invalid'), (2, 'b@example.invalid'), (3, 'c@example.invalid');" \
    'INSERT INTO pba_order (id, customer_id, total) VALUES' \
    '  (1, 1, 10.00), (2, 1, 20.00), (3, 2, 30.00), (4, 3, 40.00);' \
    'ANALYZE;'
}

if [[ -n "${PBA_TEST_DSN:-}" ]]; then
  if ! command -v psql >/dev/null 2>&1; then
    printf 'FAIL  psql is required when PBA_TEST_DSN is set\n'
    exit 1
  fi
  DSN_INFO="$(python3 - "$PBA_TEST_DSN" <<'PY'
import sys
import urllib.parse

parts = urllib.parse.urlparse(sys.argv[1])
if parts.scheme not in ("postgres", "postgresql"):
    sys.exit("PBA_TEST_DSN must be a postgresql:// URI")
print(parts.hostname or "localhost")
print(parts.port or 5432)
print(urllib.parse.unquote(parts.username or "postgres"))
print(urllib.parse.unquote(parts.password or ""))
print((parts.path or "/postgres").lstrip("/"))
PY
)" || {
    printf 'FAIL  could not parse PBA_TEST_DSN\n'
    exit 1
  }
  mapfile -t DSN_PARTS <<< "$DSN_INFO"
  PG_HOST="${DSN_PARTS[0]}"
  PG_PORT="${DSN_PARTS[1]}"
  PG_USER="${DSN_PARTS[2]}"
  PG_PASSWORD="${DSN_PARTS[3]}"
  MODE="external"
else
  if ! command -v docker >/dev/null 2>&1; then
    printf 'SKIP  docker not found; set PBA_TEST_DSN to test an external server\n'
    exit 0
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'SKIP  docker daemon not reachable; set PBA_TEST_DSN to test an external server\n'
    exit 0
  fi
  MODE="docker"
fi

if [[ "$MODE" == "docker" ]]; then
  CONTAINER="pba-smoke-$$-$(date +%s)"
  PORT="$(free_port)"
  if ! docker run -d --name "$CONTAINER" \
      -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_USER=postgres \
      -e POSTGRES_DB=postgres \
      -p "127.0.0.1:${PORT}:5432" \
      postgres:17 >/dev/null; then
    fail "start postgres:17 container"
    finish
    exit 1
  fi

  READY=0
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done
  if (( READY == 0 )); then
    fail "postgres:17 became ready"
    finish
    exit 1
  fi

  PG_USER="postgres"
  PGVER="$(docker exec "$CONTAINER" psql -U postgres -d postgres -Atqc \
    "SELECT current_setting('server_version_num')::int / 10000;" | tr -d '[:space:]')"

  if seed_sql | docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null; then
    pass "seed tiny schema"
  else
    fail "seed tiny schema"
  fi
else
  PGVER="$(psql "$PBA_TEST_DSN" -Atqc \
    "SELECT current_setting('server_version_num')::int / 10000;" | tr -d '[:space:]')"
  if seed_sql | psql "$PBA_TEST_DSN" -v ON_ERROR_STOP=1 >/dev/null; then
    pass "seed tiny schema"
  else
    fail "seed tiny schema"
  fi
fi

if [[ ! "$PGVER" =~ ^[0-9]+$ ]]; then
  fail "detect PostgreSQL major version"
  finish
  exit 1
fi

RUN_DIR="${TMP_DIR}/run"
mkdir -p "$RUN_DIR"
COLLECT_LOG="${TMP_DIR}/collect.log"

if [[ "$MODE" == "docker" ]]; then
  (
    cd "$RUN_DIR" || exit 1
    "$COLLECTOR" --docker-container "$CONTAINER" --user postgres
  ) >"$COLLECT_LOG" 2>&1
else
  (
    cd "$RUN_DIR" || exit 1
    if [[ -n "$PG_PASSWORD" ]]; then
      export PGPASSWORD="$PG_PASSWORD"
    else
      unset PGPASSWORD
    fi
    "$COLLECTOR" --host "$PG_HOST" --port "$PG_PORT" --user "$PG_USER"
  ) >"$COLLECT_LOG" 2>&1
fi
COLLECT_RC=$?

if (( COLLECT_RC == 0 )); then
  pass "collector exited 0"
else
  fail "collector exited 0 (got ${COLLECT_RC}); log follows"
  sed 's/^/      /' "$COLLECT_LOG"
fi

shopt -s nullglob
BUNDLES=("$RUN_DIR"/zk_audit_PG"${PGVER}"_*)
BUNDLE=""
if [[ ${#BUNDLES[@]} -eq 1 && -d "${BUNDLES[0]}" ]]; then
  BUNDLE="${BUNDLES[0]}"
  pass "bundle directory matches zk_audit_PG${PGVER}_*"
else
  fail "one bundle directory matches zk_audit_PG${PGVER}_* (found ${#BUNDLES[@]})"
fi

if [[ -z "$BUNDLE" ]]; then
  finish
  exit 1
fi

MANIFEST="${BUNDLE}/manifest.json"
if [[ -f "$MANIFEST" ]] && python3 -m json.tool "$MANIFEST" >/dev/null 2>&1; then
  pass "manifest.json exists and parses"
else
  fail "manifest.json exists and parses"
fi

mapfile -t DATABASES < <(python3 - "$MANIFEST" <<'PY' 2>/dev/null
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception:
    sys.exit(0)
for name in manifest.get("databases", []):
    print(name)
PY
)

if [[ ${#DATABASES[@]} -gt 0 ]]; then
  pass "manifest lists ${#DATABASES[@]} database(s)"
else
  fail "manifest lists at least one database"
fi

CATALOGS=("$BUNDLE"/catalog_db_*.json)
STATS=("$BUNDLE"/stat_db_*.json)
if [[ ${#CATALOGS[@]} -eq ${#DATABASES[@]} ]]; then
  pass "one catalog_db_*.json per database (${#CATALOGS[@]})"
else
  fail "one catalog_db_*.json per database (${#CATALOGS[@]} files, ${#DATABASES[@]} databases)"
fi
if [[ ${#STATS[@]} -eq ${#DATABASES[@]} ]]; then
  pass "one stat_db_*.json per database (${#STATS[@]})"
else
  fail "one stat_db_*.json per database (${#STATS[@]} files, ${#DATABASES[@]} databases)"
fi

for db in "${DATABASES[@]}"; do
  for prefix in catalog stat; do
    file="${BUNDLE}/${prefix}_db_${db}.json"
    if [[ ! -f "$file" ]]; then
      fail "${prefix}_db_${db}.json exists"
    elif python3 -m json.tool "$file" >/dev/null 2>&1; then
      pass "${prefix}_db_${db}.json exists and parses"
    else
      fail "${prefix}_db_${db}.json parses"
    fi
  done
done

TOTAL_BYTES="$(python3 - "$BUNDLE" <<'PY'
import os
import sys

total = 0
for root, _dirs, files in os.walk(sys.argv[1]):
    for name in files:
        total += os.path.getsize(os.path.join(root, name))
print(total)
PY
)"

if [[ "$TOTAL_BYTES" =~ ^[0-9]+$ ]] && (( TOTAL_BYTES < 2 * 1024 * 1024 )); then
  pass "bundle size under 2 MB (${TOTAL_BYTES} bytes)"
else
  fail "bundle size under 2 MB (${TOTAL_BYTES:-unknown} bytes)"
fi

finish
