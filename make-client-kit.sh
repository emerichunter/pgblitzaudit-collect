#!/usr/bin/env bash
# =============================================================================
#  Build the client-facing collection kit.
#
#  Produces a folder and a zip containing only what a client needs to run a
#  collection and verify the result: the collectors, the dump SQL, the
#  acceptance tests and the collection guide. No engine, no report SQL.
#
#  Usage:
#    ./make-client-kit.sh                 # version from VERSION file
#    ./make-client-kit.sh --version 1.0.3 --out /tmp/kits
#
#  Output:
#    dist/pgblitzaudit-kit-<version>/
#    dist/pgblitzaudit-kit-<version>.zip
#    prints the zip path and its SHA-256
# =============================================================================
set -euo pipefail

VERSION=""
OUT="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$VERSION" ]] && VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo "1.0")"

NAME="pgblitzaudit-kit-${VERSION}"
STAGE="${ROOT}/${OUT}/${NAME}"

# Files that belong in a client handoff. Explicit list: adding a file to the
# repository must be a deliberate decision, not an accident of a glob.
FILES=(
  "zk_collect.sh"
  "zk_collect.ps1"
  "zk_catalog_dump.sql"
  "zk_stat_dump.sql"
  "sys_collect.sh"
  "tests/battle-test.sh"
  "tests/battle-test.ps1"
  "docs/collection-guide.md"
  "LICENSE"
)

echo ""
echo "  Building $NAME"

for f in "${FILES[@]}"; do
  if [[ ! -f "$ROOT/$f" ]]; then
    echo "  ERR  missing required file: $f" >&2
    exit 1
  fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE/tests" "$STAGE/docs"

for f in "${FILES[@]}"; do
  cp "$ROOT/$f" "$STAGE/$f"
done

# The one file that is generated rather than copied: it must point at the guide,
# not at the repository README (which talks about the engine).
cat > "$STAGE/START-HERE.md" <<'EOF'
# Start here

You have been given the pgblitzaudit collection kit. It reads schema metadata
and aggregate statistics from a PostgreSQL cluster and writes them to a
folder. It does not read row data and needs no internet access.

**Read `docs/collection-guide.md` and follow it top to bottom.** It covers:

1. What access the collector needs
2. The read-only account to create (exact SQL)
3. The one command to run, on Windows or Linux
4. How to verify the bundle before you send it
5. How to package and return it
6. Troubleshooting
7. What leaves your server, for your security reviewer

Quick version, if you already know what you are doing:

```bash
PGPASSWORD='...' ./zk_collect.sh --host db.example.com --user blitz_ro
bash tests/battle-test.sh zk_audit_*/
```

```powershell
$env:PGPASSWORD = "..."
.\zk_collect.ps1 -PgHost db.example.com -User blitz_ro
.\tests\battle-test.ps1 -Bundle .\zk_audit_PG*
```

Send back the resulting folder, zipped, with its SHA-256.

Source: https://github.com/emerichunter/pgblitzaudit-collect
EOF

# Checksums so the recipient can prove the kit arrived intact.
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -r sha256sum > SHA256SUMS )

ZIP="${ROOT}/${OUT}/${NAME}.zip"
rm -f "$ZIP"
if command -v zip > /dev/null 2>&1; then
  ( cd "${ROOT}/${OUT}" && zip -qr "${NAME}.zip" "${NAME}" )
elif command -v python3 > /dev/null 2>&1; then
  # zip(1) is not everywhere; python3 is.
  python3 - "$ROOT/${OUT}" "$NAME" <<'PY'
import os, sys, zipfile
base, name = sys.argv[1], sys.argv[2]
out = os.path.join(base, name + ".zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(os.path.join(base, name)):
        for f in files:
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, base))
PY
else
  echo "  ERR  neither zip nor python3 is available" >&2
  exit 1
fi

SUM="$(sha256sum "$ZIP" | awk '{print $1}')"

echo "  OK   ${OUT}/${NAME}/ ($(find "$STAGE" -type f | wc -l | tr -d ' ') files)"
echo "  OK   ${OUT}/${NAME}.zip ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "  SHA-256  ${SUM}"
echo ""
echo "  Hand over the zip only. The guide is inside it."
