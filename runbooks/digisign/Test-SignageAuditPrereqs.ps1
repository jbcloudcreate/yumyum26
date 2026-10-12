<#
.SYNOPSIS
    Reports which SQLite access routes are available on this server.

.DESCRIPTION
    READ ONLY. Opens nothing for writing, installs nothing, changes nothing.
    Run it on swpapp-digisign and send the output back.

    Windows ships no SQLite engine, so clearing the audit log needs one of:
      1. sqlite3.exe          - single 1.5 MB binary, no installer
      2. PSSQLite module      - works on Windows PowerShell 5.1
      3. App's own DLLs       - already on this server, but needs PowerShell 7
      4. Off-box              - copy the .db somewhere with tooling

.EXAMPLE
    .\Test-SignageAuditPrereqs.ps1 -DbPath 'E:\signagefeedadmin\data\feed.db'
#>

[CmdletBinding()]
param(
    [string] $DbPath  = 'E:\signagefeedadmin\data\feed.db',
    [string] $AppPath
)

$ErrorActionPreference = 'Continue'
$routes = [ordered]@{}

function Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Hit($t)  { Write-Host "  [YES] $t" -ForegroundColor Green }
function Miss($t) { Write-Host "  [no ] $t" -ForegroundColor DarkGray }
function Note($t) { Write-Host "       $t" -ForegroundColor Gray }
function Warn($t) { Write-Host "  [!!] $t" -ForegroundColor Yellow }

Write-Host "SWP Signage - audit log prerequisite check" -ForegroundColor White
Write-Host "Host: $env:COMPUTERNAME   User: $env:USERDOMAIN\$env:USERNAME   $(Get-Date -f 'yyyy-MM-dd HH:mm')"

# ------------------------------------------------------------------ database
Head 'The database'
if (Test-Path $DbPath) {
    $f = Get-Item $DbPath
    Hit "Found: $DbPath"
    Note ("Size {0:N0} bytes, modified {1}" -f $f.Length, $f.LastWriteTime)
    foreach ($s in '-wal','-shm') {
        if (Test-Path "$DbPath$s") { Warn "$($f.Name)$s present - database is in WAL mode" }
    }
    # SQLite files start with the ASCII header "SQLite format 3".
    $head = [System.IO.File]::ReadAllBytes($DbPath)[0..14] -as [byte[]]
    $magic = [System.Text.Encoding]::ASCII.GetString($head)
    if ($magic -eq 'SQLite format 3') { Hit 'Valid SQLite file header' }
    else { Warn "Unexpected header: '$magic'" }
} else {
    Warn "Not found at $DbPath"
    Note 'Locate it with:'
    Note '  Get-ChildItem E:\ -Filter feed.db -Recurse -ErrorAction SilentlyContinue | Select FullName,Length'
}

# ------------------------------------------------------------------ route 1
Head 'Route 1 - sqlite3.exe'
$sq = @()
$sq += (Get-Command sqlite3.exe -ErrorAction SilentlyContinue | Select-Object -Expand Source)
foreach ($root in 'C:\', 'E:\') {
    if (Test-Path $root) {
        $sq += (Get-ChildItem $root -Filter 'sqlite3.exe' -Recurse -ErrorAction SilentlyContinue -Force |
                Select-Object -First 3 -Expand FullName)
    }
}
$sq = $sq | Where-Object { $_ } | Select-Object -Unique
if ($sq) { $sq | ForEach-Object { Hit "Found: $_" }; $routes['sqlite3.exe'] = 'AVAILABLE' }
else {
    Miss 'sqlite3.exe not present anywhere on C: or E:'
    Note 'Obtain: sqlite-tools-win-x64 from sqlite.org, or via your GitHub route.'
    Note 'Single file, no installer, no registry.'
    $routes['sqlite3.exe'] = 'needs the binary copied over'
}

# ------------------------------------------------------------------ route 2
Head 'Route 2 - PSSQLite module (works on Windows PowerShell 5.1)'
$mod = Get-Module PSSQLite -ListAvailable -ErrorAction SilentlyContinue
if ($mod) {
    Hit "Installed: version $($mod[0].Version) at $($mod[0].ModuleBase)"
    $routes['PSSQLite'] = 'AVAILABLE'
} else {
    Miss 'PSSQLite not installed'
    Write-Host '       testing PSGallery reachability...' -ForegroundColor DarkGray
    try {
        $r = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/' `
             -UseBasicParsing -TimeoutSec 15
        Hit "PSGallery reachable (HTTP $($r.StatusCode))"
        Note 'Install with:  Install-Module PSSQLite -Scope CurrentUser -Force'
        $routes['PSSQLite'] = 'installable from PSGallery'
    } catch {
        Miss "PSGallery unreachable: $($_.Exception.Message -replace '\s+',' ')"
        Note 'Alternative: Save-Module PSSQLite -Path C:\temp on a machine that can reach it,'
        Note 'then copy the folder into a $env:PSModulePath location here.'
        $routes['PSSQLite'] = 'needs offline module copy'
    }
}

# ------------------------------------------------------------------ route 3
Head "Route 3 - the application's own SQLite DLLs"
Note "This PowerShell: $($PSVersionTable.PSVersion)  ($($PSVersionTable.PSEdition))"

# PS7 counts as available if this session already IS PS7, not only if
# pwsh.exe happens to be on PATH.
$ps7Cmd     = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$runningPs7 = $PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7
$ps7        = $ps7Cmd -or $runningPs7

if ($runningPs7)   { Hit "Running under PowerShell $($PSVersionTable.PSVersion) now" }
elseif ($ps7Cmd)   { Hit "PowerShell 7 present: $($ps7Cmd.Source)" }
else               { Miss 'PowerShell 7 not installed (this is Windows PowerShell)' }

if (-not $AppPath) {
    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    if (Test-Path $appcmd) {
        $AppPath = (& $appcmd list vdir /text:physicalPath |
                    Where-Object { $_ -match 'signageadmin' } | Select-Object -First 1)
        if ($AppPath) { $AppPath = $AppPath.Trim() }
    }
}
if ($AppPath -and (Test-Path $AppPath)) {
    Note "App path: $AppPath"
    $need = 'Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll',
            'SQLitePCLRaw.provider.e_sqlite3.dll','SQLitePCLRaw.batteries_v2.dll'
    $have = @()
    foreach ($d in $need) {
        if (Test-Path (Join-Path $AppPath $d)) { Hit "  $d"; $have += $d } else { Miss "  $d" }
    }
    $native = Get-ChildItem $AppPath -Filter 'e_sqlite3.dll' -Recurse -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($native) { Hit "  native e_sqlite3.dll: $($native.FullName)" }
    else         { Miss '  native e_sqlite3.dll not found' }

    if ($have.Count -eq $need.Count -and $native -and $ps7) {
        $routes['App DLLs via PS7'] = 'AVAILABLE - no new files needed'
    } elseif ($have.Count -eq $need.Count -and $native) {
        $routes['App DLLs via PS7'] = 'DLLs present but PowerShell 7 missing'
        Warn 'These target .NET 10 and CANNOT be loaded by Windows PowerShell 5.1.'
    } else {
        $routes['App DLLs via PS7'] = 'DLLs not all present'
    }
} else {
    Miss 'Could not resolve the application path - pass -AppPath'
    $routes['App DLLs via PS7'] = 'unknown'
}

# ------------------------------------------------------------------ context
Head 'Other context'
try {
    $rt = & dotnet --list-runtimes 2>$null
    if ($rt) { Hit "dotnet runtimes: $(($rt | Measure-Object).Count) installed" ; $rt | Select-Object -First 4 | ForEach-Object { Note "  $_" } }
    $sdk = & dotnet --list-sdks 2>$null
    if ($sdk) { Hit "dotnet SDK present"; $sdk | ForEach-Object { Note "  $_" } }
    else      { Miss 'no dotnet SDK (runtime only) - cannot compile a helper on the box' }
} catch { Miss 'dotnet CLI not on PATH' }

$appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
if (Test-Path $appcmd) {
    Write-Host "`n  IIS application pools:" -ForegroundColor Gray
    & $appcmd list apppool | ForEach-Object { Note "  $_" }
}

# ------------------------------------------------------------------ verdict
Head 'Summary - send this back'
$routes.GetEnumerator() | ForEach-Object {
    $c = if ($_.Value -like 'AVAILABLE*') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-22} {1}" -f $_.Key, $_.Value) -ForegroundColor $c
}
$win = $routes.GetEnumerator() | Where-Object { $_.Value -like 'AVAILABLE*' } | Select-Object -First 1
Write-Host ''
if ($win) { Write-Host "  => Use: $($win.Key)" -ForegroundColor Green }
else      { Write-Host "  => No route is open yet. The summary above shows what each needs." -ForegroundColor Yellow }
Write-Host ''
