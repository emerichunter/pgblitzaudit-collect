#!/usr/bin/env bash
# =============================================================================
#  Bundle acceptance test (bash) — same checks as tests/battle-test.ps1
#
#  Usage:
#    bash tests/battle-test.sh BUNDLE_DIR
#    bash tests/battle-test.sh BUNDLE_DIR --reports REPORTS_DIR
#    bash tests/battle-test.sh BUNDLE_DIR --password 'the-db-password'
#
#  Exit code 0 = every check passed, 1 = at least one failed.
#
#  python3 is used for JSON validation when available. Without it the script
#  falls back to structural checks (truncation detection) and skips the
#  manifest assertions, saying so.
# =============================================================================
set -uo pipefail

BUNDLE=""
REPORTS=""
PW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reports)  REPORTS="${2:-}"; shift 2 ;;
    --password) PW="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          BUNDLE="$1"; shift ;;
  esac
done

if [[ -z "$BUNDLE" ]]; then
  echo "usage: bash tests/battle-test.sh BUNDLE_DIR [--reports DIR] [--password PW]" >&2
  exit 1
fi

PASS=0; FAIL=0
FINDINGS=()

_green() { printf '\033[32m%s\033[0m' "$1"; }
_red()   { printf '\033[31m%s\033[0m' "$1"; }
_ok()    { PASS=$((PASS+1)); printf '  %s  %s\n' "$(_green PASS)" "$1"; }
_bad()   { FAIL=$((FAIL+1)); FINDINGS+=("$1${2:+ -- $2}"); printf '  %s  %s\n' "$(_red FAIL)" "$1"; [[ -n "${2:-}" ]] && printf '        \033[90m%s\033[0m\n' "$2"; }
_info()  { printf '  \033[90m%s\033[0m\n' "$1"; }
_step()  { printf '\n\033[36m== %s\033[0m\n' "$1"; }

# A python3 that exists but cannot import json is worse than none: it turns
# every manifest check into a misleading failure. Prove it works first.
HAS_PY=0
if command -v python3 > /dev/null 2>&1 && python3 -c 'import json' > /dev/null 2>&1; then
  HAS_PY=1
fi

echo ""
echo "  myblitzaudit acceptance test (bash)"
_info "Host    : $(uname -s) $(uname -m)"
_info "Python  : $( ((HAS_PY)) && python3 -V 2>&1 || echo 'not found — structural checks only' )"
_info "Bundle  : $BUNDLE"

# ---------------------------------------------------------------------------
_step "Bundle shape"
if [[ ! -d "$BUNDLE" ]]; then
  _bad "bundle directory does not exist"
  echo ""; printf '  %s\n' "$(_red 'RESULT: FAILED')"; exit 1
fi
BUNDLE="$(cd "$BUNDLE" && pwd)"

if [[ ! -f "$BUNDLE/manifest.json" ]]; then
  _bad "manifest.json is missing"
  echo ""; printf '  %s\n' "$(_red 'RESULT: FAILED')"; exit 1
fi
_ok "manifest.json exists"

_bom() { head -c 3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -q '^efbbbf'; }

if _bom "$BUNDLE/manifest.json"; then _bad "manifest.json starts with a byte-order mark"; else _ok "manifest.json has no byte-order mark"; fi

if iconv -f UTF-8 -t UTF-8 "$BUNDLE/manifest.json" > /dev/null 2>&1; then
  _ok "manifest.json is valid UTF-8"
else
  _bad "manifest.json is not valid UTF-8"
fi

# A failed query leaves the error message where the JSON should be.
if head -c 8 "$BUNDLE/manifest.json" | grep -qi '^ERROR'; then
  _bad "manifest.json contains a SQL error, not JSON"
fi

# ---------------------------------------------------------------------------
_step "Manifest contents"
if (( HAS_PY )); then
  MAN_OUT="$(python3 - "$BUNDLE/manifest.json" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception as e:
    print("PARSE_FAIL " + str(e)[:120]); raise SystemExit(0)
ver_key = next((k for k in ("blitz_version", "zk_audit_version") if k in m), "")
srv_key = next((k for k in ("mysql_version", "pg_version") if k in m), "")
print("VERSION_KEY " + ver_key)
print("SERVER_KEY " + srv_key)
print("VERSION " + str(m.get(ver_key, "")))
print("DBCOUNT " + str(len(m.get("databases") or [])))
print("DBS " + " ".join(m.get("databases") or []))
print("FILECOUNT " + str(len(m.get("files") or [])))
for f in (m.get("files") or []):
    print("FILE %s\t%s" % (f.get("name"), f.get("size_bytes")))
PY
)"
  if grep -q '^PARSE_FAIL' <<< "$MAN_OUT"; then
    _bad "manifest.json does not parse" "$(grep '^PARSE_FAIL' <<< "$MAN_OUT" | cut -d' ' -f2-)"
  else
    _ok "manifest.json parses as JSON"
    VKEY="$(awk '/^VERSION_KEY/{print $2}' <<< "$MAN_OUT")"
    if [[ -n "$VKEY" ]]; then _ok "manifest version field: $VKEY=$(awk '/^VERSION/{print $2}' <<< "$MAN_OUT")"; else _bad "manifest has no version field"; fi
    SK="$(awk '/^SERVER_KEY/{print $2}' <<< "$MAN_OUT")"
    if [[ -n "$SK" ]]; then _ok "manifest records the server version ($SK)"; else _bad "manifest records no server version"; fi
    DBC="$(awk '/^DBCOUNT/{print $2}' <<< "$MAN_OUT")"
    if [[ "${DBC:-0}" -ge 1 ]]; then _ok "manifest lists $DBC database(s): $(awk '/^DBS/{$1="";print substr($0,2)}' <<< "$MAN_OUT")"; else _bad "manifest lists no databases"; fi

    # files must exist at the recorded size
    MISMATCH=0
    while IFS=$'\t' read -r name size; do
      [[ -z "$name" ]] && continue
      if [[ ! -f "$BUNDLE/$name" ]]; then _bad "listed file is missing: $name"; MISMATCH=1; continue; fi
      actual="$(wc -c < "$BUNDLE/$name" | tr -d ' ')"
      if [[ "$actual" != "$size" ]]; then _bad "size mismatch for $name" "manifest=$size disk=$actual"; MISMATCH=1; fi
    done < <(awk -F'\t' '/^FILE /{sub(/^FILE /,""); print}' <<< "$MAN_OUT")
    (( MISMATCH == 0 )) && _ok "every listed file exists at the recorded size"
  fi
else
  _info "python3 not found — skipping manifest assertions"
fi

# ---------------------------------------------------------------------------
_step "JSON integrity"
shopt -s nullglob
JSONS=("$BUNDLE"/*.json)
shopt -u nullglob
if [[ ${#JSONS[@]} -eq 0 ]]; then _bad "no JSON files in the bundle"; fi

for f in "${JSONS[@]}"; do
  name="$(basename "$f")"
  if _bom "$f"; then _bad "$name starts with a byte-order mark"; continue; fi

  if head -c 64 "$f" | grep -qi '^ERROR [0-9]'; then
    _bad "$name contains a SQL error, not JSON" "$(head -c 120 "$f" | tr '\n' ' ')"
    continue
  fi
  if grep -qE 'Unknown column|You have an error in your SQL syntax|Access denied' "$f" 2>/dev/null; then
    _bad "$name contains a SQL error string" "$(grep -m1 -oE 'ERROR [0-9]+.{0,80}' "$f" | head -1)"
    continue
  fi

  size_kb=$(( ($(wc -c < "$f") + 512) / 1024 ))
  if (( HAS_PY )); then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8-sig"))' "$f" 2>/dev/null; then
      _ok "$name parses (${size_kb} KB)"
    else
      _bad "$name does not parse" "$(python3 -c 'import json,sys
try: json.load(open(sys.argv[1],encoding="utf-8-sig"))
except Exception as e: print(str(e)[:120])' "$f" 2>&1 | head -1)"
    fi
  else
    first="$(head -c 1 "$f")"; last="$(tail -c 2000 "$f" | tr -d '[:space:]' | tail -c 1)"
    if { [[ "$first" == "{" && "$last" == "}" ]] || [[ "$first" == "[" && "$last" == "]" ]]; }; then
      _ok "$name is well-formed (${size_kb} KB, structural check)"
    else
      _bad "$name looks truncated (${size_kb} KB)"
    fi
  fi
done

# ---------------------------------------------------------------------------
_step "Per-database files"
if (( HAS_PY )) && [[ -n "${MAN_OUT:-}" ]] && ! grep -q '^PARSE_FAIL' <<< "${MAN_OUT:-}"; then
  DBS="$(awk '/^DBS/{$1="";print substr($0,2)}' <<< "$MAN_OUT")"
  for db in $DBS; do
    for kind in "catalog_db_${db}.json" "stat_db_${db}.json"; do
      p="$BUNDLE/$kind"
      if [[ ! -f "$p" ]]; then _bad "missing: $kind"; continue; fi
      len=$(wc -c < "$p" | tr -d ' ')
      if (( len < 1024 )); then _bad "$kind is suspiciously small ($len bytes)"; else _ok "$kind ($(( (len+512)/1024 )) KB)"; fi
    done
    if [[ -f "$BUNDLE/schema_dump_${db}.sql" ]]; then
      _ok "schema_dump_${db}.sql"
    else
      _info "no schema_dump_${db}.sql (collector may have run with --no-schema-dump)"
    fi
  done
else
  for p in "$BUNDLE"/catalog_db_*.json "$BUNDLE"/stat_db_*.json; do
    [[ -f "$p" ]] || continue
    len=$(wc -c < "$p" | tr -d ' ')
    if (( len < 1024 )); then _bad "$(basename "$p") is suspiciously small ($len bytes)"; else _ok "$(basename "$p") ($(( (len+512)/1024 )) KB)"; fi
  done
fi

# ---------------------------------------------------------------------------
_step "Content spot checks"
HASHHITS=""
for f in "${JSONS[@]}"; do
  if grep -qE '"(authentication_string|rolpassword)"[[:space:]]*:[[:space:]]*"[^"]+"' "$f" 2>/dev/null; then
    HASHHITS="$HASHHITS $(basename "$f")"
  fi
done
if [[ -n "$HASHHITS" ]]; then _bad "password hashes present in:$HASHHITS"; else _ok "no password hashes in any JSON file"; fi

if [[ -n "$PW" ]]; then
  LEAKS=""
  for f in "$BUNDLE"/*; do
    [[ -f "$f" ]] || continue
    grep -qF -- "$PW" "$f" 2>/dev/null && LEAKS="$LEAKS $(basename "$f")"
  done
  if [[ -n "$LEAKS" ]]; then _bad "the password appears in:$LEAKS"; else _ok "the password does not appear in any bundle file"; fi
fi

# ---------------------------------------------------------------------------
if [[ -n "$REPORTS" ]]; then
  _step "Reports"
  if [[ ! -d "$REPORTS" ]]; then
    _bad "reports directory does not exist: $REPORTS"
  else
    shopt -s nullglob
    HTML=("$REPORTS"/*.html)
    shopt -u nullglob
    [[ ${#HTML[@]} -eq 0 ]] && _bad "no HTML reports in $REPORTS"
    for h in "${HTML[@]}"; do
      name="$(basename "$h")"
      len=$(wc -c < "$h" | tr -d ' ')
      if ! head -c 200 "$h" | grep -qi '<!doctype'; then _bad "$name has no doctype"; continue; fi
      if (( len < 10240 )); then _bad "$name is only $(( len/1024 )) KB"; continue; fi
      ext=$(grep -oE 'https?://' "$h" 2>/dev/null | wc -l | tr -d ' ')
      if (( ext > 0 )); then _bad "$name references $ext external URL(s) — not offline"; else _ok "$name is offline ($(( len/1024 )) KB, 0 external URLs)"; fi
    done
  fi
fi

# ---------------------------------------------------------------------------
_step "Summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"

if (( FAIL > 0 )); then
  echo ""
  echo "  Findings:"
  for f in "${FINDINGS[@]}"; do printf '   - %s\n' "$f"; done
  echo ""
  printf '  %s\n' "$(_red 'RESULT: FAILED')"
  exit 1
fi

printf '  %s\n' "$(_green 'RESULT: PASSED')"
exit 0
