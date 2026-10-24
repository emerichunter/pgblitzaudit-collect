#Requires -Version 5.1
<#
.SYNOPSIS
  pgBlitzAudit Collect - Zero Knowledge PostgreSQL snapshot bundle

.DESCRIPTION
  Collects a complete schema + statistics snapshot from a PostgreSQL instance
  without extracting any user data.

  Outputs a timestamped directory containing:
    catalog_snapshot.json   - schema, indexes, roles, settings (zk_catalog_dump.sql)
    stat_snapshot.json      - query stats, table stats, bloat, locks (zk_stat_dump.sql)
    schema_dump.sql         - DDL structure (pg_dump --schema-only)
    statistics_dump.sql     - planner statistics (pg_dump --statistics-only, PG18+)
    manifest.json           - collection metadata + file inventory

.PARAMETER Host
  PostgreSQL server hostname (default: localhost)
.PARAMETER Port
  PostgreSQL port (default: 5432)
.PARAMETER Database
  Database to snapshot (default: postgres)
.PARAMETER User
  PostgreSQL user (default: postgres)
.PARAMETER OutputDir
  Output directory path (default: auto-named zk_audit_YYYYMMDD_HHMMSS)
.PARAMETER DockerContainer
  If set, run psql/pg_dump inside this Docker container (name or ID)
.PARAMETER Password
  PostgreSQL password (or set PGPASSWORD env var)
.PARAMETER NoSchemaDump
  Skip pg_dump --schema-only (useful if you only want live stats)
.PARAMETER NoStatDump
  Skip pg_dump --statistics-only
.PARAMETER Databases
  Comma-separated list of databases for pg_dump (default: same as -Database)

.EXAMPLE
  # Local PostgreSQL
  .\zk_collect.ps1 -Host localhost -Port 5432 -Database mydb -User postgres

.EXAMPLE
  # Docker container
  .\zk_collect.ps1 -DockerContainer pg-test-report -Database postgres -User postgres

.EXAMPLE
  # With password, custom output directory
  .\zk_collect.ps1 -Host db.example.com -User readonly -Password secret -OutputDir ./my_audit
#>

[CmdletBinding()]
param(
    [string]$PgHost    = "localhost",
    [int]   $Port      = 5432,
    [string]$Database  = "postgres",
    [string]$User      = "postgres",
    [string]$Password  = "",
    [string]$OutputDir = "",
    [string]$DockerContainer = "",
    [string]$Databases = "",
    [switch]$NoSchemaDump,
    [switch]$NoStatDump
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host "  $msg" -ForegroundColor Cyan
}
function Write-Ok([string]$msg) {
    Write-Host "  OK  $msg" -ForegroundColor Green
}
function Write-Warn([string]$msg) {
    Write-Host "  WARN  $msg" -ForegroundColor Yellow
}
function Write-Err([string]$msg) {
    Write-Host "  ERR  $msg" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------

if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputDir = "zk_audit_$timestamp"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = Resolve-Path $OutputDir

Write-Host ""
Write-Host "  pgBlitzAudit Collect v1.0" -ForegroundColor White
Write-Host "  Output: $OutputDir" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# Password / env setup
# ---------------------------------------------------------------------------

$origPgPassword = $env:PGPASSWORD
if ($Password) { $env:PGPASSWORD = $Password }

# ---------------------------------------------------------------------------
# Build psql / pg_dump command wrappers
# ---------------------------------------------------------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Psql {
    param([string]$SqlFile, [string]$OutFile, [string]$Db = $Database)

    $absScript = Resolve-Path $SqlFile

    if ($DockerContainer) {
        # Copy SQL file into container, run, copy result back
        $tmpIn  = "/tmp/zk_in_$(Split-Path -Leaf $SqlFile)"
        $tmpOut = "/tmp/zk_out_$(Split-Path -Leaf $OutFile)"

        docker cp $absScript "${DockerContainer}:$tmpIn" | Out-Null
        $rc = docker exec $DockerContainer `
            sh -c "psql -U $User -d $Db -A -t -q -f $tmpIn > $tmpOut 2>&1"
        docker cp "${DockerContainer}:$tmpOut" $OutFile | Out-Null
        docker exec $DockerContainer rm -f $tmpIn $tmpOut | Out-Null
    } else {
        $connStr = "-h $PgHost -p $Port -U $User -d $Db"
        & psql $connStr.Split() -A -t -q -f $absScript -o $OutFile 2>&1 | Out-Null
    }
}

function Invoke-PgDump {
    param([string[]]$ExtraArgs, [string]$OutFile, [string]$Db = $Database)

    if ($DockerContainer) {
        $tmpOut = "/tmp/zk_pgdump_$(Split-Path -Leaf $OutFile)"
        $argStr = ($ExtraArgs -join " ")
        docker exec $DockerContainer `
            sh -c "pg_dump -U $User -d $Db $argStr > $tmpOut 2>&1"
        docker cp "${DockerContainer}:$tmpOut" $OutFile | Out-Null
        docker exec $DockerContainer rm -f $tmpOut | Out-Null
    } else {
        $connArgs = @("-h", $PgHost, "-p", $Port.ToString(), "-U", $User, "-d", $Db)
        & pg_dump @connArgs @ExtraArgs -f $OutFile 2>&1 | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Step 1: catalog_snapshot.json
# ---------------------------------------------------------------------------

Write-Step "Collecting catalog snapshot (schema, indexes, roles, settings)..."
$catalogSql = Join-Path $scriptDir "zk_catalog_dump.sql"
$catalogOut = Join-Path $OutputDir "catalog_snapshot.json"

try {
    Invoke-Psql -SqlFile $catalogSql -OutFile $catalogOut
    $size = (Get-Item $catalogOut).Length
    Write-Ok "catalog_snapshot.json  ($([math]::Round($size/1KB, 1)) KB)"
} catch {
    Write-Warn "catalog_snapshot.json failed: $_"
}

# ---------------------------------------------------------------------------
# Step 2: stat_snapshot.json
# ---------------------------------------------------------------------------

Write-Step "Collecting statistics snapshot (pg_stat_statements, bloat, locks)..."
$statSql = Join-Path $scriptDir "zk_stat_dump.sql"
$statOut  = Join-Path $OutputDir "stat_snapshot.json"

try {
    Invoke-Psql -SqlFile $statSql -OutFile $statOut
    $size = (Get-Item $statOut).Length
    Write-Ok "stat_snapshot.json  ($([math]::Round($size/1KB, 1)) KB)"
} catch {
    Write-Warn "stat_snapshot.json failed: $_"
}

# ---------------------------------------------------------------------------
# Detect PostgreSQL major version (needed for pg_dump option selection)
# ---------------------------------------------------------------------------

$pgVerNum = 0
try {
    if ($DockerContainer) {
        $pgVerNum = [int](docker exec $DockerContainer psql -U $User -d $Database -A -t -q `
            -c "SELECT current_setting('server_version_num')::int;" 2>$null)
    } else {
        $pgVerNum = [int](& psql -h $PgHost -p $Port -U $User -d $Database -A -t -q `
            -c "SELECT current_setting('server_version_num')::int;" 2>$null)
    }
} catch { $pgVerNum = 0 }

$pgMajor = [math]::Floor($pgVerNum / 10000)
Write-Host "  Detected PostgreSQL major version: $pgMajor" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Step 3: pg_dump --schema-only
# NOTE: --schema-only excludes sequence current values.
#       Sequence data is captured via zk_catalog_dump.sql (pg_sequences view).
#       For PG17+, --no-statistics keeps schema dump lean (stats go in step 4).
# ---------------------------------------------------------------------------

if (-not $NoSchemaDump) {
    Write-Step "Running pg_dump --schema-only..."
    $schemaOut = Join-Path $OutputDir "schema_dump.sql"

    $schemaArgs = @("--schema-only", "--no-password")
    # PG18+ supports --no-statistics to keep schema dump lean (stats go in statistics_dump.sql)
    if ($pgMajor -ge 18) { $schemaArgs += "--no-statistics" }

    try {
        Invoke-PgDump -ExtraArgs $schemaArgs -OutFile $schemaOut
        $size = (Get-Item $schemaOut).Length
        Write-Ok "schema_dump.sql  ($([math]::Round($size/1KB, 1)) KB)"
    } catch {
        Write-Warn "schema_dump.sql failed: $_"
    }
}

# ---------------------------------------------------------------------------
# Step 4: pg_dump --statistics-only  (PostgreSQL 18+ only)
# PG17 and earlier: planner statistics are captured via pg_stats in
#   catalog_snapshot.json (planner_stats section). No pg_dump equivalent.
# PG18+: --statistics-only dumps ANALYZE statistics objects separately.
# Note on --sequence-data: excluded by design - sequence current values are
#   captured via pg_sequences in catalog_snapshot.json instead.
# ---------------------------------------------------------------------------

if (-not $NoStatDump) {
    $statsOut = Join-Path $OutputDir "statistics_dump.sql"

    if ($pgMajor -ge 18) {
        Write-Step "Running pg_dump --statistics-only (PG18+)..."
        try {
            Invoke-PgDump -ExtraArgs @("--statistics-only", "--no-password") -OutFile $statsOut
            $size = (Get-Item $statsOut).Length
            Write-Ok "statistics_dump.sql  ($([math]::Round($size/1KB, 1)) KB)"
        } catch {
            Write-Warn "statistics_dump.sql failed: $_"
            "-- pg_dump --statistics-only failed" | Out-File $statsOut -Encoding utf8
        }
    } else {
        Write-Step "Skipping pg_dump --statistics-only (PG$pgMajor - requires PG18+)..."
        Write-Host "    Planner stats captured via pg_stats in catalog_snapshot.json" -ForegroundColor DarkGray
        $noteLines = @(
            "-- pg_dump --statistics-only requires PostgreSQL 18+.",
            "-- Planner statistics are available in catalog_snapshot.json (planner_stats section).",
            "-- PostgreSQL major version detected: $pgMajor"
        )
        $noteLines | Out-File $statsOut -Encoding utf8
        Write-Ok "statistics_dump.sql  (note written)"
    }
}

# ---------------------------------------------------------------------------
# Step 5: manifest.json
# ---------------------------------------------------------------------------

Write-Step "Writing manifest..."

$pgVersion = ""
try {
    if ($DockerContainer) {
        $pgVersion = docker exec $DockerContainer psql -U $User -d $Database -A -t -q `
            -c "SELECT version();" 2>$null
    } else {
        $pgVersion = & psql -h $PgHost -p $Port -U $User -d $Database -A -t -q `
            -c "SELECT version();" 2>$null
    }
    $pgVersion = $pgVersion.Trim()
} catch {}

$files = Get-ChildItem $OutputDir -File | ForEach-Object {
    [ordered]@{
        name       = $_.Name
        size_bytes = $_.Length
        modified   = $_.LastWriteTimeUtc.ToString("o")
    }
}

$manifest = [ordered]@{
    zk_audit_version = "1.0"
    generated_at     = (Get-Date -Format "o")
    pg_version       = $pgVersion
    database         = $Database
    host             = if ($DockerContainer) { "docker:$DockerContainer" } else { "${PgHost}:$Port" }
    files            = $files
}

$manifest | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutputDir "manifest.json") -Encoding utf8
Write-Ok "manifest.json"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if ($Password -or $origPgPassword) {
    $env:PGPASSWORD = if ($origPgPassword) { $origPgPassword } else { "" }
}

Write-Host ""
Write-Host "  Bundle ready: $OutputDir" -ForegroundColor White
Write-Host ""

# Print file summary
Get-ChildItem $OutputDir -File | ForEach-Object {
    $kb = [math]::Round($_.Length / 1KB, 1)
    Write-Host ("    {0,-32} {1,8} KB" -f $_.Name, $kb) -ForegroundColor DarkGray
}
Write-Host ""
