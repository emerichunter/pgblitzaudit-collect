#Requires -Version 5.1
<#
.SYNOPSIS
    Evidence-producing acceptance test for a myblitzaudit bundle.

.DESCRIPTION
    Checks a bundle for the failure modes that a "it ran fine" test misses:
    unparseable JSON, a byte-order mark, SQL error text written into an output
    file, missing per-database files, manifest/file mismatches, and reports that
    phone home.

    Runs on Windows PowerShell 5.1 and PowerShell 7, on any machine — the bundle
    can be produced elsewhere and verified here.

    Exit code 0 = every check passed, 1 = at least one failed.

.PARAMETER Bundle
    Existing bundle directory to verify.

.PARAMETER Collect
    Run my_collect.ps1 first, then verify what it produced. Requires
    -Bundle to name the destination directory.

.PARAMETER Collector
    Path to my_collect.ps1. Default: the parent directory of this script.

.PARAMETER Target
    Arguments passed through to the collector when -Collect is used, for example
    "-HostName db.example.com -User audit_reader".

.PARAMETER ReportsDir
    Optional. Directory of rendered HTML reports to check for offline compliance.

.PARAMETER Password
    Optional. Fails the run if this string appears anywhere in the bundle.

.EXAMPLE
    # Verify a bundle someone sent you
    .\battle-test.ps1 -Bundle .\my_audit_MY80_20260510_143022

.EXAMPLE
    # Collect from a server and verify the result in one go
    .\battle-test.ps1 -Collect -Bundle .\blitz_evidence `
                      -Target "-HostName db.example.com -User audit_reader -Password ***"

.EXAMPLE
    # Include the rendered reports in the check
    .\battle-test.ps1 -Bundle .\my_audit_MY80_20260510_143022 -ReportsDir .\reports
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [switch]$Collect,
    [string]$Collector = "",
    [string]$Target = "",
    [string]$ReportsDir = "",
    [string]$Password = ""
)

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Result plumbing
# ---------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Findings = New-Object System.Collections.ArrayList

function Ok([string]$msg) {
    $script:Pass++
    Write-Host "  PASS  $msg" -ForegroundColor Green
}

function Bad([string]$msg, [string]$detail = "") {
    $script:Fail++
    [void]$script:Findings.Add($msg + $(if ($detail) { " -- $detail" } else { "" }))
    Write-Host "  FAIL  $msg" -ForegroundColor Red
    if ($detail) { Write-Host "        $detail" -ForegroundColor DarkRed }
}

function Info([string]$msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

# Reads a file as strict UTF-8. Returns $null when the bytes are not valid UTF-8.
function Read-Utf8Strict([string]$Path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $enc = New-Object System.Text.UTF8Encoding($false, $true)
        return $enc.GetString($bytes)
    } catch {
        return $null
    }
}

# Structural check for JSON that ConvertFrom-Json refuses to model: balanced
# braces, and an even number of unescaped quotes. Catches truncation, which is
# the failure this harness exists to find.
function Test-JsonShape([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -lt 2) { return $false }
    $first = $t[0]; $last = $t[$t.Length - 1]
    $enclosureOk = (($first -eq '{' -and $last -eq '}') -or ($first -eq '[' -and $last -eq ']'))
    if (-not $enclosureOk) { return $false }
    $quotes = 0
    $escaped = $false
    foreach ($ch in $t.ToCharArray()) {
        if ($escaped) { $escaped = $false; continue }
        if ($ch -eq [char]'\\') { $escaped = $true; continue }
        if ($ch -eq [char]'"') { $quotes++ }
    }
    return (($quotes % 2) -eq 0)
}

function Test-Bom([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return $true }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return $true }  # UTF-16 LE
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return $true }  # UTF-16 BE
    return $false
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  myblitzaudit acceptance test" -ForegroundColor White
Info "PowerShell : $($PSVersionTable.PSVersion)"
Info "Edition    : $($PSVersionTable.PSEdition)"
Info "OS         : $([System.Environment]::OSVersion.VersionString)"
Info "64-bit     : $([System.Environment]::Is64BitProcess)"
Info "Bundle     : $Bundle"
Info "Started    : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"

# ---------------------------------------------------------------------------
# Optional: collect first
# ---------------------------------------------------------------------------
if ($Collect) {
    Step "Collect"

    if (-not $Collector) {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $Collector = Join-Path (Split-Path -Parent $here) "my_collect.ps1"
    }
    if (-not (Test-Path -LiteralPath $Collector)) {
        Bad "collector not found: $Collector"
        Write-Host ""
        Write-Host "  Cannot continue." -ForegroundColor Red
        exit 1
    }
    Info "collector: $Collector"

    if (Test-Path -LiteralPath $Bundle) { Remove-Item -LiteralPath $Bundle -Recurse -Force }

    $argList = @()
    if ($Target) { $argList = $Target -split '\s+' | Where-Object { $_ } }
    $argList += @("-OutputDir", $Bundle)

    $log = Join-Path ([System.IO.Path]::GetTempPath()) ("blitz_collect_" + [System.Guid]::NewGuid().ToString("N").Substring(0,8) + ".log")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $psExe = (Get-Process -Id $PID).Path
    & $psExe -NoProfile -File $Collector @argList *>&1 | Tee-Object -FilePath $log | Out-Null
    $rc = $LASTEXITCODE
    $sw.Stop()

    if ($rc -eq 0 -and (Test-Path -LiteralPath $Bundle)) {
        Ok "collector exited 0 in $([int]$sw.Elapsed.TotalSeconds)s"
    } else {
        Bad "collector failed (exit $rc)" "log: $log"
        Get-Content $log -Tail 20 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkRed }
    }
}

# ---------------------------------------------------------------------------
# 1. Bundle shape
# ---------------------------------------------------------------------------
Step "Bundle shape"

if (-not (Test-Path -LiteralPath $Bundle)) {
    Bad "bundle directory does not exist"
    Write-Host ""
    Write-Host "  Cannot continue." -ForegroundColor Red
    exit 1
}

$bundleFull = (Resolve-Path -LiteralPath $Bundle).Path
$manifestPath = Join-Path $bundleFull "manifest.json"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Bad "manifest.json is missing"
    Write-Host ""
    Write-Host "  Cannot continue: no manifest to check." -ForegroundColor Red
    exit 1
}
Ok "manifest.json exists"

if (Test-Bom $manifestPath) { Bad "manifest.json starts with a byte-order mark" } else { Ok "manifest.json has no byte-order mark" }

$manifestText = Read-Utf8Strict $manifestPath
if ($null -eq $manifestText) {
    Bad "manifest.json is not valid UTF-8"
} else {
    Ok "manifest.json is valid UTF-8"
}

$manifest = $null
try {
    $manifest = $manifestText | ConvertFrom-Json
    Ok "manifest.json parses as JSON"
} catch {
    Bad "manifest.json does not parse" $_.Exception.Message
    Write-Host ""
    Write-Host "  Cannot continue without a manifest." -ForegroundColor Red
    exit 1
}

# Two bundle dialects: myblitzaudit (blitz_version, mysql_version) and
# pgblitzaudit (zk_audit_version, pg_version). Check what this one actually is.
$versionKey = ""
foreach ($candidate in @("blitz_version", "zk_audit_version")) {
    if ($null -ne $manifest.$candidate) { $versionKey = $candidate; break }
}
if ($versionKey) { Ok "manifest has '$versionKey' = $($manifest.$versionKey)" } else { Bad "manifest has no version field (blitz_version or zk_audit_version)" }

$serverKey = ""
foreach ($candidate in @("mysql_version", "pg_version")) {
    if ($null -ne $manifest.$candidate) { $serverKey = $candidate; break }
}
if ($serverKey) { Ok "manifest records the server version ($serverKey)" } else { Bad "manifest records no server version" }

foreach ($key in @("generated_at", "host", "databases", "files")) {
    if ($null -ne $manifest.$key) { Ok "manifest has '$key'" } else { Bad "manifest is missing '$key'" }
}

$dbs = @($manifest.databases)
if ($dbs.Count -ge 1) { Ok "manifest lists $($dbs.Count) database(s): $($dbs -join ', ')" } else { Bad "manifest lists no databases" }

# ---------------------------------------------------------------------------
# 2. Manifest vs disk
# ---------------------------------------------------------------------------
Step "Manifest vs disk"

$listed = @($manifest.files)
if ($listed.Count -eq 0) { Bad "manifest files[] is empty" }

foreach ($f in $listed) {
    $p = Join-Path $bundleFull $f.name
    if (-not (Test-Path -LiteralPath $p)) {
        Bad "listed file is missing: $($f.name)"
        continue
    }
    $actual = (Get-Item -LiteralPath $p).Length
    if ($actual -ne [int64]$f.size_bytes) {
        Bad "size mismatch for $($f.name)" "manifest=$($f.size_bytes) disk=$actual"
    } else {
        Ok "size matches: $($f.name) ($actual bytes)"
    }
}

$onDisk = @(Get-ChildItem -LiteralPath $bundleFull -File |
            Where-Object { $_.Name -ne "manifest.json" -and $_.Name -ne "battle-test-evidence.json" })
$listedNames = @($listed | ForEach-Object { $_.name })
foreach ($f in $onDisk) {
    if ($listedNames -notcontains $f.Name) { Bad "file on disk is not in the manifest: $($f.Name)" }
}

# ---------------------------------------------------------------------------
# 3. Every JSON file is real JSON
# ---------------------------------------------------------------------------
Step "JSON integrity"

$jsonFiles = @(Get-ChildItem -LiteralPath $bundleFull -Filter *.json -File)
if ($jsonFiles.Count -eq 0) { Bad "no JSON files in the bundle" }

foreach ($f in $jsonFiles) {
    if (Test-Bom $f.FullName) {
        Bad "$($f.Name) starts with a byte-order mark"
        continue
    }

    $text = Read-Utf8Strict $f.FullName
    if ($null -eq $text) { Bad "$($f.Name) is not valid UTF-8"; continue }

    # A failed SQL statement leaves its error message where the JSON should be.
    if ($text -match '^\s*ERROR\s+\d+') {
        Bad "$($f.Name) contains a SQL error, not JSON" $text.Substring(0, [Math]::Min(120, $text.Length))
        continue
    }
    if ($text -match 'Unknown column|You have an error in your SQL syntax|Access denied') {
        $squashed = $text -replace '\s+', ' '
        Bad "$($f.Name) contains a SQL error string" $squashed.Substring(0, [Math]::Min(120, $squashed.Length))
        continue
    }

    $okJson = $false
    $errMsg = ""
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { [void]($text | ConvertFrom-Json -AsHashtable); $okJson = $true } catch { $errMsg = $_.Exception.Message }
    }
    if (-not $okJson) {
        try { [void]($text | ConvertFrom-Json); $okJson = $true } catch { $errMsg = $_.Exception.Message }
    }
    if (-not $okJson -and $errMsg -match 'empty string') {
        # Valid JSON with an "" key (a group with no application_name, for
        # instance). ConvertFrom-Json cannot represent that before PS 6.
        $okJson = Test-JsonShape $text
        if ($okJson) { Ok "$($f.Name) is well-formed ($([int]($f.Length / 1024)) KB, empty key names; structural check)" }
    }
    if ($okJson -and $errMsg -notmatch 'empty string') {
        Ok "$($f.Name) parses ($([int]($f.Length / 1024)) KB)"
    } elseif (-not $okJson) {
        Bad "$($f.Name) does not parse" ($errMsg.Substring(0, [Math]::Min(120, $errMsg.Length)))
    }
}

# ---------------------------------------------------------------------------
# 4. Per-database files
# ---------------------------------------------------------------------------
Step "Per-database files"

foreach ($db in $dbs) {
    foreach ($kind in @("catalog_db_$db.json", "stat_db_$db.json")) {
        $p = Join-Path $bundleFull $kind
        if (-not (Test-Path -LiteralPath $p)) {
            Bad "missing: $kind"
            continue
        }
        $len = (Get-Item -LiteralPath $p).Length
        # A 75-byte catalog file is a SQL error message, not a snapshot.
        if ($len -lt 1024) { Bad "$kind is suspiciously small ($len bytes)" } else { Ok "$kind ($([int]($len / 1024)) KB)" }
    }

    $schema = Join-Path $bundleFull "schema_dump_$db.sql"
    if (Test-Path -LiteralPath $schema) {
        if ((Get-Item -LiteralPath $schema).Length -gt 0) { Ok "schema_dump_$db.sql" } else { Bad "schema_dump_$db.sql is empty" }
    } else {
        Info "no schema_dump_$db.sql (collector may have been run with -NoSchemaDump)"
    }
}

# ---------------------------------------------------------------------------
# 5. Content spot checks
# ---------------------------------------------------------------------------
Step "Content spot checks"

$global = Join-Path $bundleFull "global_snapshot.json"
if (Test-Path -LiteralPath $global) {
    $g = Read-Utf8Strict $global
    if ($g -match '"users"') { Ok "global snapshot carries the user inventory" } else { Bad "global snapshot has no users section" }
} else {
    Info "no global_snapshot.json (expected for pgBlitzAudit bundles)"
}

# No password hashes anywhere, in either dialect: MySQL authentication_string,
# PostgreSQL rolpassword.
$hashHits = @()
foreach ($f in $jsonFiles) {
    $t = Read-Utf8Strict $f.FullName
    # Only a key/value pair is a leaked hash. A statement digest that merely
    # mentions the column (SELECT ... rolpassword IS NOT NULL) is not.
    if ($t -and ($t -match '"authentication_string"\s*:\s*"[^"]+"' -or $t -match '"rolpassword"\s*:\s*"[^"]+"')) {
        $hashHits += $f.Name
    }
}
if ($hashHits.Count -gt 0) { Bad "password hashes present in: $($hashHits -join ', ')" } else { Ok "no password hashes in any JSON file" }

if ($Password) {
    $leaks = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $bundleFull -File)) {
        $t = Read-Utf8Strict $f.FullName
        if ($t -and $t.Contains($Password)) { $leaks += $f.Name }
    }
    if ($leaks.Count -gt 0) { Bad "the password appears in: $($leaks -join ', ')" } else { Ok "the password does not appear in any bundle file" }
}

# ---------------------------------------------------------------------------
# 6. Reports, when provided
# ---------------------------------------------------------------------------
if ($ReportsDir) {
    Step "Reports"

    if (-not (Test-Path -LiteralPath $ReportsDir)) {
        Bad "reports directory does not exist: $ReportsDir"
    } else {
        $html = @(Get-ChildItem -LiteralPath $ReportsDir -Filter *.html -File)
        if ($html.Count -eq 0) { Bad "no HTML reports in $ReportsDir" }

        foreach ($h in $html) {
            $t = Read-Utf8Strict $h.FullName
            if ($null -eq $t) { Bad "$($h.Name) is not valid UTF-8"; continue }
            if ($t -notmatch '<!DOCTYPE') { Bad "$($h.Name) has no doctype"; continue }
            if ($h.Length -lt 10240) { Bad "$($h.Name) is only $([int]($h.Length / 1024)) KB"; continue }

            $external = [regex]::Matches($t, 'https?://')
            if ($external.Count -gt 0) {
                Bad "$($h.Name) references $($external.Count) external URL(s) — not offline"
            } else {
                Ok "$($h.Name) is offline ($([int]($h.Length / 1024)) KB, 0 external URLs)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Evidence dump
# ---------------------------------------------------------------------------
$totalBytes = 0
foreach ($f in @(Get-ChildItem -LiteralPath $bundleFull -File)) { $totalBytes += $f.Length }

$evidence = [ordered]@{
    tool             = "myblitzaudit battle-test"
    generated_at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    powershell       = $PSVersionTable.PSVersion.ToString()
    edition          = $PSVersionTable.PSEdition
    os               = [System.Environment]::OSVersion.VersionString
    bundle           = $bundleFull
    manifest_version = $manifest.$versionKey
    server_version   = $manifest.$serverKey
    mariadb          = $manifest.is_mariadb
    pg_major         = $manifest.pg_major
    databases        = $dbs
    file_count       = @($onDisk).Count
    total_bytes      = $totalBytes
    passed           = $script:Pass
    failed           = $script:Fail
    findings         = $script:Findings
}
$evidencePath = Join-Path $bundleFull "battle-test-evidence.json"
try {
    ($evidence | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $evidencePath -Encoding UTF8
    if (Test-Bom $evidencePath) {
        # Write again without a BOM; 5.1 adds one for -Encoding UTF8.
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 4), $enc)
    }
    Info "evidence written to $evidencePath"
} catch {
    Info "could not write evidence file: $($_.Exception.Message)"
}

Step "Summary"
Write-Host "  $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })

if ($script:Fail -gt 0) {
    Write-Host ""
    Write-Host "  Findings:" -ForegroundColor Red
    foreach ($f in $script:Findings) { Write-Host "   - $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  RESULT: FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  RESULT: PASSED" -ForegroundColor Green
exit 0
