#Requires -Version 5.1
<#
.SYNOPSIS
  pgBlitzAudit Collect v2.0 - Zero Knowledge PostgreSQL snapshot bundle (multi-database)

.DESCRIPTION
  Collects schema and statistics metadata from every connectable database in a
  PostgreSQL cluster without extracting any user data.

  Outputs one timestamped directory containing, per database:
    catalog_db_<db>.json       - schema, indexes, roles, settings (zk_catalog_dump.sql)
    stat_db_<db>.json          - query stats, table stats, bloat, locks (zk_stat_dump.sql)
    schema_dump_<db>.sql       - DDL structure (pg_dump --schema-only)
    statistics_dump_<db>.sql   - planner statistics (pg_dump --statistics-only, PG18+)
  plus a manifest.json describing the run.

  Bundle layout and manifest are identical to the bash collector (zk_collect.sh v2.0),
  so the same replayer handles both.

.PARAMETER PgHost
  PostgreSQL server hostname (default: localhost)
.PARAMETER Port
  PostgreSQL port (default: 5432)
.PARAMETER Database
  Collect a single database (default: every connectable database)
.PARAMETER Databases
  Comma-separated list of databases to collect (ignored when -Database is set)
.PARAMETER User
  PostgreSQL user (default: postgres)
.PARAMETER Password
  PostgreSQL password (or set PGPASSWORD env var)
.PARAMETER OutputDir
  Output directory (default: zk_audit_PG<major>_yyyyMMdd_HHmmss)
.PARAMETER DockerContainer
  Run psql/pg_dump inside this Docker container (name or ID)
.PARAMETER NoSchemaDump
  Skip pg_dump --schema-only
.PARAMETER NoStatDump
  Skip pg_dump --statistics-only (PG18+)

.EXAMPLE
  # Whole cluster, local PostgreSQL
  .\zk_collect.ps1 -PgHost localhost -User postgres

.EXAMPLE
  # Whole cluster inside a Docker container
  .\zk_collect.ps1 -DockerContainer my-postgres -User postgres

.EXAMPLE
  # One database only
  .\zk_collect.ps1 -PgHost db.example.com -User readonly -Database mydb -Password secret

.EXAMPLE
  # Two specific databases, custom output directory
  .\zk_collect.ps1 -PgHost db.example.com -User readonly -Databases "app,reporting" -OutputDir .\my_audit
#>

[CmdletBinding()]
param(
    [string]$PgHost    = "localhost",
    [int]   $Port      = 5432,
    [string]$Database  = "",
    [string]$Databases = "",
    [string]$User      = "postgres",
    [string]$Password  = "",
    [string]$OutputDir = "",
    [string]$DockerContainer = "",
    [switch]$NoSchemaDump,
    [switch]$NoStatDump
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  ERR  $msg" -ForegroundColor Red }
function Write-Gray([string]$msg) { Write-Host "  $msg" -ForegroundColor DarkGray }

function Get-SizeKb([string]$path) {
    if (Test-Path -LiteralPath $path) {
        return [int][math]::Round(((Get-Item -LiteralPath $path).Length + 512) / 1024, 0)
    }
    return 0
}

function ConvertTo-JsonText([string]$s) {
    if ($null -eq $s) { return "" }
    $s = $s.Replace('\', '\\')
    $s = $s.Replace('"', '\"')
    $s = $s.Replace("`r", '\r')
    $s = $s.Replace("`n", '\n')
    $s = $s.Replace("`t", '\t')
    return $s
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# Inline SQL -> stdout (string)
function Invoke-PsqlText {
    param([string]$Sql, [string]$Db = "postgres")

    $raw = $null
    if ($DockerContainer) {
        $raw = & docker exec $DockerContainer psql -U $User -d $Db -A -t -q -c $Sql 2>$null
    } else {
        $raw = & psql -h $PgHost -p $Port -U $User -d $Db -A -t -q -c $Sql 2>$null
    }
    if ($null -eq $raw) { return "" }
    $text = ($raw -join "`n")
    return $text.Replace("`r", "").Trim()
}

# SQL file -> output file
function Invoke-PsqlFile {
    param([string]$SqlFile, [string]$OutFile, [string]$Db)

    $absScript = (Resolve-Path -LiteralPath $SqlFile).Path

    if ($DockerContainer) {
        $leaf   = "$PID-" + (Split-Path -Leaf $SqlFile)
        $tmpIn  = "/tmp/zk_in_$leaf"
        $tmpOut = "/tmp/zk_out_$PID-" + (Split-Path -Leaf $OutFile)

        & docker cp $absScript "${DockerContainer}:$tmpIn" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp of $SqlFile failed (exit $LASTEXITCODE)" }

        & docker exec $DockerContainer sh -c "psql -U `"$User`" -d `"$Db`" -A -t -q -f `"$tmpIn`" > `"$tmpOut`" 2>&1"
        $rc = $LASTEXITCODE

        & docker cp "${DockerContainer}:$tmpOut" $OutFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp of the result failed (exit $LASTEXITCODE)" }
        & docker exec $DockerContainer rm -f $tmpIn $tmpOut | Out-Null

        if ($rc -ne 0) { throw "psql exited with code $rc" }
    } else {
        & psql -h $PgHost -p $Port -U $User -d $Db -A -t -q -f $absScript -o $OutFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "psql exited with code $LASTEXITCODE" }
    }

    if (-not (Test-Path -LiteralPath $OutFile)) { throw "no output produced: $OutFile" }
}

# pg_dump -> output file
function Invoke-PgDump {
    param([string]$OutFile, [string]$Db, [string[]]$ExtraArgs)

    if ($null -eq $ExtraArgs) { $ExtraArgs = @() }

    if ($DockerContainer) {
        $tmpOut = "/tmp/zk_pgdump_$PID-" + (Split-Path -Leaf $OutFile)
        $argStr = ($ExtraArgs -join " ")
        & docker exec $DockerContainer sh -c "pg_dump -U `"$User`" -d `"$Db`" $argStr > `"$tmpOut`" 2>&1"
        $rc = $LASTEXITCODE
        & docker cp "${DockerContainer}:$tmpOut" $OutFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp of the dump failed (exit $LASTEXITCODE)" }
        & docker exec $DockerContainer rm -f $tmpOut | Out-Null
        if ($rc -ne 0) { throw "pg_dump exited with code $rc" }
    } else {
        $connArgs = @("-h", $PgHost, "-p", $Port.ToString(), "-U", $User, "-d", $Db)
        & pg_dump @connArgs @ExtraArgs -f $OutFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pg_dump exited with code $LASTEXITCODE" }
    }

    if (-not (Test-Path -LiteralPath $OutFile)) { throw "no dump produced: $OutFile" }
    if ((Get-Item -LiteralPath $OutFile).Length -eq 0) { throw "dump is empty: $OutFile" }
}

# ---------------------------------------------------------------------------
# Password / environment
# ---------------------------------------------------------------------------

$origPgPassword = $env:PGPASSWORD
if ($Password) { $env:PGPASSWORD = $Password }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Step 0: detect PostgreSQL major version (before naming the output directory)
# ---------------------------------------------------------------------------

$connectDb = if ($Database) { $Database } else { "postgres" }

$pgVerNum = 0
try {
    $verText = Invoke-PsqlText -Sql "SELECT current_setting('server_version_num')::int;" -Db $connectDb
    if ($verText) { $pgVerNum = [int]$verText }
} catch { $pgVerNum = 0 }

$pgMajor = [int][math]::Floor($pgVerNum / 10000)

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------

if (-not $OutputDir) {
    $OutputDir = "zk_audit_PG$($pgMajor)_" + (Get-Date -Format "yyyyMMdd_HHmmss")
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

Write-Host ""
Write-Host "  pgBlitzAudit Collect v2.0 (PowerShell)" -ForegroundColor White
Write-Gray "Output: $OutputDir"
Write-Gray "PostgreSQL major version: $pgMajor"
Write-Host ""

$catalogSql = Join-Path $scriptDir "zk_catalog_dump.sql"
$statSql    = Join-Path $scriptDir "zk_stat_dump.sql"
if (-not (Test-Path -LiteralPath $catalogSql)) { Write-Warn "zk_catalog_dump.sql not found at: $catalogSql" }
if (-not (Test-Path -LiteralPath $statSql))    { Write-Warn "zk_stat_dump.sql not found at: $statSql" }

# ---------------------------------------------------------------------------
# Step 1: discover databases
# ---------------------------------------------------------------------------

$dbList = @()

if ($Database) {
    $dbList = @($Database)
    Write-Gray "Single-database mode: $Database"
} elseif ($Databases) {
    $dbList = @($Databases.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    Write-Gray "Selected databases: $($dbList -join ' ')"
} else {
    Write-Step "Discovering databases..."
    $discoverySql = "SELECT datname FROM pg_database " +
                    "WHERE datallowconn AND datname NOT IN ('template0','template1') " +
                    "ORDER BY datname;"
    $raw = Invoke-PsqlText -Sql $discoverySql -Db $connectDb
    if ($raw) {
        $dbList = @($raw.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }
    if ($dbList.Count -eq 0) {
        Write-Warn "No connectable databases found. Falling back to 'postgres'."
        $dbList = @("postgres")
    }
    Write-Ok "Found $($dbList.Count) database(s): $($dbList -join ' ')"
}

# ---------------------------------------------------------------------------
# Step 2: catalog + statistics per database
# ---------------------------------------------------------------------------

foreach ($db in $dbList) {
    Write-Host ""
    Write-Step "--- Database: $db ---"

    if (Test-Path -LiteralPath $catalogSql) {
        $out = Join-Path $OutputDir "catalog_db_$db.json"
        Write-Step "  Collecting catalog snapshot..."
        try {
            Invoke-PsqlFile -SqlFile $catalogSql -OutFile $out -Db $db
            Write-Ok "catalog_db_$db.json  ($(Get-SizeKb $out) KB)"
        } catch {
            Write-Warn "catalog_db_$db.json failed: $_"
        }
    }

    if (Test-Path -LiteralPath $statSql) {
        $out = Join-Path $OutputDir "stat_db_$db.json"
        Write-Step "  Collecting statistics snapshot..."
        try {
            Invoke-PsqlFile -SqlFile $statSql -OutFile $out -Db $db
            Write-Ok "stat_db_$db.json  ($(Get-SizeKb $out) KB)"
        } catch {
            Write-Warn "stat_db_$db.json failed: $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: pg_dump --schema-only per database
# ---------------------------------------------------------------------------

if (-not $NoSchemaDump) {
    Write-Host ""
    foreach ($db in $dbList) {
        Write-Step "pg_dump --schema-only: $db..."
        $out = Join-Path $OutputDir "schema_dump_$db.sql"
        $schemaArgs = @("--schema-only", "--no-password")
        if ($pgMajor -ge 18) { $schemaArgs += "--no-statistics" }
        try {
            Invoke-PgDump -OutFile $out -Db $db -ExtraArgs $schemaArgs
            Write-Ok "schema_dump_$db.sql  ($(Get-SizeKb $out) KB)"
        } catch {
            Write-Warn "schema_dump_$db.sql failed: $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 4: pg_dump --statistics-only (PG18+ only)
# ---------------------------------------------------------------------------

if (-not $NoStatDump) {
    Write-Host ""
    foreach ($db in $dbList) {
        $out = Join-Path $OutputDir "statistics_dump_$db.sql"
        if ($pgMajor -ge 18) {
            Write-Step "pg_dump --statistics-only (PG18+): $db..."
            try {
                Invoke-PgDump -OutFile $out -Db $db -ExtraArgs @("--statistics-only", "--no-password")
                Write-Ok "statistics_dump_$db.sql  ($(Get-SizeKb $out) KB)"
            } catch {
                Write-Warn "statistics_dump_$db.sql failed: $_"
                Write-Utf8NoBom $out "-- pg_dump --statistics-only failed for database: $db`n"
            }
        } else {
            Write-Gray "Skipping pg_dump --statistics-only for $db (PG$pgMajor - requires PG18+)"
            $note = "-- pg_dump --statistics-only requires PostgreSQL 18+.`n" +
                    "-- Planner statistics are available in catalog_db_$db.json (planner_stats section).`n" +
                    "-- PostgreSQL major version detected: $pgMajor`n"
            Write-Utf8NoBom $out $note
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: manifest.json (built by hand so arrays never collapse on PS 5.1)
# ---------------------------------------------------------------------------

Write-Host ""
Write-Step "Writing manifest..."

$pgVersion = ""
try { $pgVersion = Invoke-PsqlText -Sql "SELECT version();" -Db $connectDb } catch { $pgVersion = "" }

$hostVal = if ($DockerContainer) { "docker:$DockerContainer" } else { "${PgHost}:$Port" }
$generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$dbJson = (@($dbList | ForEach-Object { '"' + (ConvertTo-JsonText $_) + '"' })) -join ","

$filesJson = @()
$allFiles = @(Get-ChildItem -LiteralPath $OutputDir -File)
$ordered = @($allFiles | Where-Object { $_.Extension -eq ".json" -and $_.Name -ne "manifest.json" } | Sort-Object Name) +
           @($allFiles | Where-Object { $_.Extension -eq ".sql" } | Sort-Object Name)

foreach ($f in $ordered) {
    $modified = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $filesJson += '{"name":"' + (ConvertTo-JsonText $f.Name) + '","size_bytes":' + $f.Length +
                  ',"modified":"' + $modified + '"}'
}

$manifest = @"
{
  "zk_audit_version": "2.0",
  "generated_at": "$generatedAt",
  "pg_version": "$(ConvertTo-JsonText $pgVersion)",
  "pg_major": $pgMajor,
  "host": "$(ConvertTo-JsonText $hostVal)",
  "databases": [$dbJson],
  "files": [$(($filesJson -join ","))]
}
"@

Write-Utf8NoBom (Join-Path $OutputDir "manifest.json") $manifest
Write-Ok "manifest.json"

# ---------------------------------------------------------------------------
# Restore PGPASSWORD
# ---------------------------------------------------------------------------

if ($Password) {
    if ($origPgPassword) { $env:PGPASSWORD = $origPgPassword } else { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Bundle ready: $OutputDir" -ForegroundColor White
Write-Gray "Databases collected: $($dbList -join ' ')"
Write-Host ""
foreach ($f in @(Get-ChildItem -LiteralPath $OutputDir -File | Sort-Object Name)) {
    Write-Host ("  {0,-44} {1,8} KB" -f $f.Name, [int][math]::Round(($f.Length + 512) / 1024, 0)) -ForegroundColor DarkGray
}
Write-Host ""
