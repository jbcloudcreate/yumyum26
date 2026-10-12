<#
.SYNOPSIS
    Archives and clears entries from the SWP Signage Feed Admin audit log.

.DESCRIPTION
    Operates directly on the application's SQLite database. No application
    change, rebuild or redeployment is required.

    The script is SAFE BY DEFAULT: with no -Execute switch it performs a dry
    run, reporting exactly what would be removed and changing nothing.

    Every run, dry or live:
      * takes a timestamped backup of the database
      * exports the affected rows to CSV before deleting anything
      * records the purge itself as an audit entry, so the act of clearing
        is never invisible
      * verifies row counts before and after

.PARAMETER AppPath
    Physical path of the deployed application (the folder containing
    App_Data\feed.db). Discovered via appcmd if omitted.

.PARAMETER DbPath
    Full path to feed.db. Use this when the database does not live under the
    application folder, e.g. 'E:\signagefeedadmin\data\feed.db'. Takes
    precedence over -AppPath and skips all discovery.

.PARAMETER Before
    Delete entries with TimestampUtc strictly older than this UTC date.

.PARAMETER FeedId
    Limit to a single feed (servicedesk | systems | datacenter | news).
    Omit to apply across all feeds.

.PARAMETER All
    Delete every audit entry regardless of date. Mutually exclusive with
    -Before. Must be combined with -Execute to take effect.

.PARAMETER Execute
    Perform the deletion. Without this the script only reports.

.EXAMPLE
    .\Clear-SignageAuditLog.ps1 -DbPath 'E:\signagefeedadmin\data\feed.db' -Before '2026-10-13'
    Dry run against a database outside the application folder.

.EXAMPLE
    .\Clear-SignageAuditLog.ps1 -Before '2026-10-13'
    Dry run: shows what a pre-handover purge would remove.

.EXAMPLE
    .\Clear-SignageAuditLog.ps1 -Before '2026-10-13' -Execute
    Archives and clears everything before the handover date.

.EXAMPLE
    .\Clear-SignageAuditLog.ps1 -Before (Get-Date).AddMonths(-12) -Execute
    Rolling 12-month retention trim. Suitable for a scheduled task.
#>

[CmdletBinding(DefaultParameterSetName = 'ByDate')]
param(
    [string] $AppPath,
    [string] $DbPath,

    [Parameter(ParameterSetName = 'ByDate')]
    [datetime] $Before,

    [Parameter(ParameterSetName = 'Everything')]
    [switch] $All,

    [ValidateSet('servicedesk', 'systems', 'datacenter', 'news')]
    [string] $FeedId,

    [string] $SqliteExe,
    [string] $AppPoolName = 'SignageFeedAdminPool',
    [string] $WorkDir     = 'E:\SignageAdmin\AuditMaintenance',
    [switch] $Execute
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Start-Transcript -Path (Join-Path $WorkDir "audit-purge-$stamp.log") | Out-Null

# Set once the pool is stopped, cleared once it is started again. If the run
# fails in between, the catch block brings the site back up rather than
# leaving signage admin down.
$script:poolStopped = $false

function Say($msg, $colour = 'Gray') { Write-Host $msg -ForegroundColor $colour }
function Mark($msg) { Say "`n=== $msg ===" 'Cyan' }

try {
    # ---------------------------------------------------------------- 1. locate
    Mark 'Step 1 - locate the application and database'

    if ($DbPath) {
        # Explicit path wins outright. Nothing is inferred.
        if (-not (Test-Path $DbPath)) { throw "Database not found at the -DbPath given: $DbPath" }
        $dbPath = (Resolve-Path $DbPath).Path
        Say "  Database : $dbPath  (from -DbPath)"
    }
    else {
        if (-not $AppPath) {
            $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
            if (-not (Test-Path $appcmd)) { throw "appcmd not found. Pass -AppPath or -DbPath explicitly." }
            $raw = & $appcmd list vdir /text:physicalPath |
                   Where-Object { $_ -match 'signageadmin' } | Select-Object -First 1
            if (-not $raw) { throw "Could not discover the app path. Pass -AppPath or -DbPath explicitly." }
            $AppPath = $raw.Trim()
        }
        Say "  App path : $AppPath"

        # The database location is whatever Feed:DbPath says in the DEPLOYED
        # config, which is not necessarily the repository default of
        # App_Data\feed.db. Read it rather than assume it. Environment-specific
        # files win, matching ASP.NET Core's own precedence.
        $dbPath = $null
        foreach ($cfgName in 'appsettings.Production.json', 'appsettings.json') {
            $cfgFile = Join-Path $AppPath $cfgName
            if (-not (Test-Path $cfgFile)) { continue }
            try   { $configured = (Get-Content $cfgFile -Raw | ConvertFrom-Json).Feed.DbPath }
            catch { Say "  (could not parse $cfgName - skipping)" 'Yellow'; continue }
            if (-not $configured) { continue }

            # An absolute path is used as-is; a relative one resolves against
            # the application root, exactly as the app itself resolves it.
            $candidate = if ([System.IO.Path]::IsPathRooted($configured)) { $configured }
                         else { Join-Path $AppPath $configured }
            Say "  Config   : $cfgName -> Feed:DbPath = '$configured'"
            if (Test-Path $candidate) { $dbPath = (Resolve-Path $candidate).Path; break }
            Say "             (not present at $candidate)" 'Yellow'
        }

        # Last resort: look in the usual places before giving up.
        if (-not $dbPath) {
            $guesses = @(
                (Join-Path (Join-Path $AppPath 'App_Data') 'feed.db'),
                (Join-Path (Join-Path $AppPath 'Data') 'feed.db'),
                (Join-Path $AppPath 'feed.db')
            )
            $dbPath = $guesses | Where-Object { Test-Path $_ } |
                      Select-Object -First 1 | ForEach-Object { (Resolve-Path $_).Path }
            if ($dbPath) { Say "  Found by fallback search" 'Yellow' }
        }

        if (-not $dbPath) {
            throw @"
Could not locate feed.db.

  Searched under : $AppPath
  Checked        : Feed:DbPath in appsettings*.json, then App_Data\, Data\, app root

  Pass the path directly instead, e.g.
      -DbPath 'E:\signagefeedadmin\data\feed.db'

  To find it:
      Get-ChildItem E:\ -Filter feed.db -Recurse -ErrorAction SilentlyContinue |
          Select-Object FullName, Length, LastWriteTime
"@
        }
        Say "  Database : $dbPath"
    }

    Say ("  Size     : {0:N0} bytes" -f (Get-Item $dbPath).Length)
    Say ("  Modified : {0}" -f (Get-Item $dbPath).LastWriteTime)


    # ---------------------------------------------------------------- 2. sqlite
    Mark 'Step 2 - locate sqlite3.exe'

    if (-not $SqliteExe) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'sqlite3.exe'),
            (Join-Path $WorkDir     'sqlite3.exe'),
            'C:\temp\sqlite3.exe',
            'C:\Temp\sqlite3.exe'
        ) + @(Get-Command sqlite3.exe -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty Source)
        $SqliteExe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (-not $SqliteExe) {
        throw @"
sqlite3.exe not found.

  Download the 'sqlite-tools-win-x64' bundle from https://sqlite.org/download.html,
  extract sqlite3.exe, and place it beside this script or pass -SqliteExe.
  It is a single standalone binary - nothing is installed.
"@
    }
    Say "  sqlite3  : $SqliteExe"
    Say "  Version  : $(& $SqliteExe -version)"

    # sqlite3.exe reports failure via stderr and a non-zero exit code. A native
    # command does NOT raise a terminating error in PowerShell, not even under
    # $ErrorActionPreference = 'Stop', so without this check a failed DELETE
    # would sail past and be reported as success.
    function Sql([string] $query) {
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $out = & $SqliteExe $dbPath $query 2> $errFile
            $code = $LASTEXITCODE
            $errText = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { '' }

            if ($code -ne 0) {
                throw "sqlite3 failed (exit $code): $($errText.Trim())`n  Query: $($query.Trim())"
            }
            if ($errText -and $errText.Trim()) {
                Say "  sqlite3 warning: $($errText.Trim())" 'Yellow'
            }
            return $out
        }
        finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
    }

    # Confirm this is really the signage database before going near it. A
    # mistyped -DbPath pointing at some other SQLite file would otherwise
    # fail later, after the backup and with the app pool already stopped.
    $tables = Sql "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    if ($tables -notcontains 'AuditLog') {
        throw "No AuditLog table in $dbPath. Tables present: $($tables -join ', '). Wrong database?"
    }
    Say "  Tables   : $($tables -join ', ')"
    Say "  AuditLog table confirmed" 'Green'

    # ---------------------------------------------------------------- 3. scope
    Mark 'Step 3 - determine scope'

    $where  = @()
    if ($PSCmdlet.ParameterSetName -eq 'ByDate') {
        if (-not $Before) { throw "Specify -Before <date>, or -All to clear everything." }

        # A bare date ('2026-10-13') parses as LOCAL midnight. Under BST that
        # is 23:00 UTC the previous day, which would quietly sweep up an extra
        # hour of entries. Treat a bare date as UTC midnight, which is what
        # anyone typing a date actually means. A date WITH a time is honoured
        # as local and converted, since that was clearly deliberate.
        if ($Before.TimeOfDay -eq [timespan]::Zero) {
            $cutoffUtc = [datetime]::SpecifyKind($Before, [System.DateTimeKind]::Utc)
            $note = 'bare date - treated as UTC midnight'
        } else {
            $cutoffUtc = $Before.ToUniversalTime()
            $note = "local $($Before.ToString('yyyy-MM-dd HH:mm')) converted to UTC"
        }

        $cutoff = $cutoffUtc.ToString('o')
        $where += "TimestampUtc < '$cutoff'"
        Say "  Cutoff   : entries before $cutoff"
        Say "             ($note)"
    } else {
        Say "  Cutoff   : NONE - every entry is in scope" 'Yellow'
    }
    if ($FeedId) { $where += "FeedId = '$FeedId'"; Say "  Feed     : $FeedId" }
    else         { Say "  Feed     : all feeds" }

    # Purge records are never removable, by any filter including -All. They
    # are the record that a clearance happened; a purge that could erase the
    # evidence of the previous purge would leave no trail at all. Without
    # this, a later run sweeps up the earlier purge record, because that
    # record's own timestamp sits before the next cutoff.
    $where += "Action <> 'Purge'"
    Say "  Protected: existing Purge records are never deleted" 'Green'

    $clause = 'WHERE ' + ($where -join ' AND ')

    # ---------------------------------------------------------------- 4. report
    Mark 'Step 4 - what is in the log now'

    $total    = [int](Sql "SELECT COUNT(*) FROM AuditLog;")
    $affected = [int](Sql "SELECT COUNT(*) FROM AuditLog $clause;")
    $keep     = $total - $affected

    Say "  Total entries        : $total"
    Say "  In scope for removal : $affected" 'Yellow'
    Say "  Will remain          : $keep" 'Green'

    Say "`n  Breakdown by feed (in scope):"
    Sql "SELECT FeedId, COUNT(*), MIN(TimestampUtc), MAX(TimestampUtc)
         FROM AuditLog $clause GROUP BY FeedId;" |
        ForEach-Object {
            $p = $_ -split '\|'
            Say ("    {0,-14} {1,6} rows   {2}  ->  {3}" -f $p[0], $p[1], $p[2], $p[3])
        }

    if ($affected -eq 0) { Say "`nNothing in scope. Nothing to do." 'Green'; return }

    # ---------------------------------------------------------------- 5. archive
    Mark 'Step 5 - archive before touching anything'

    $backup = Join-Path $WorkDir "feed-$stamp.db"
    Copy-Item $dbPath $backup
    foreach ($sfx in '-wal', '-shm') {
        if (Test-Path "$dbPath$sfx") { Copy-Item "$dbPath$sfx" "$backup$sfx" }
    }
    Say "  Database backup : $backup"
    Say ("  Verified        : {0:N0} bytes" -f (Get-Item $backup).Length)

    $csv = Join-Path $WorkDir "audit-removed-$stamp.csv"
    & $SqliteExe -header -csv $dbPath `
        "SELECT Id, FeedId, TimestampUtc, UserName, Action, ItemId, Summary
         FROM AuditLog $clause ORDER BY TimestampUtc;" |
        Set-Content -Path $csv -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 failed exporting the archive (exit $LASTEXITCODE). Nothing deleted." }
    $csvRows = (Get-Content $csv | Measure-Object -Line).Lines - 1
    Say "  Entries exported: $csv ($csvRows rows)"

    if ($csvRows -ne $affected) {
        throw "Export mismatch: expected $affected rows, archive holds $csvRows. Stopping."
    }
    Say "  Archive matches scope - safe to proceed" 'Green'

    # ---------------------------------------------------------------- 6. gate
    if (-not $Execute) {
        Mark 'DRY RUN - nothing was deleted'
        Say "  The archive and backup above were still produced."
        Say "  Re-run with -Execute to perform the deletion." 'Yellow'
        return
    }

    Mark 'Step 6 - stop the application'

    $appcmdExe = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'

    # Verify the pool exists before trying to stop it. appcmd returns a
    # non-terminating error for an unknown pool, which would otherwise let the
    # script delete rows while the application was still running and writing.
    $pools = & $appcmdExe list apppool /text:name
    if ($pools -notcontains $AppPoolName) {
        throw @"
App pool '$AppPoolName' not found on this server.

  Pools present:
$($pools | ForEach-Object { "    $_" } | Out-String)
  Re-run with -AppPoolName '<correct name>'.
  Nothing has been deleted. The backup and archive are in $WorkDir
"@
    }

    & $appcmdExe stop apppool /apppool.name:$AppPoolName
    $script:poolStopped = $true
    Start-Sleep -Seconds 3

    $state = & $appcmdExe list apppool $AppPoolName /text:state
    Say "  App pool '$AppPoolName' state: $state"
    if ($state -ne 'Stopped') {
        throw "App pool did not stop (state: $state). Not deleting while the app may be writing."
    }

    # ---------------------------------------------------------------- 7. delete
    Mark 'Step 7 - delete, record the purge, reclaim'

    # WindowsIdentity gives DOMAIN\user reliably, including when the script
    # runs as a scheduled task under a service account. Env vars are the
    # fallback only.
    $who = try   { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
           catch { "$env:USERDOMAIN\$env:USERNAME" }
    if ([string]::IsNullOrWhiteSpace($who) -or $who -eq '\') { $who = 'unknown' }
    $now     = (Get-Date).ToUniversalTime().ToString('o')
    $scope   = if ($clause) { $clause } else { 'ALL ENTRIES' }
    $summary = "Audit log purged: $affected entries removed ($scope). Archive: $(Split-Path $csv -Leaf)"
    # Escaped once, here, at the point of insertion. Escaping $scope as well
    # would double it and corrupt the recorded summary.
    $summarySql = $summary -replace "'", "''"
    $whoSql     = $who     -replace "'", "''"
    $feedSql    = if ($FeedId) { $FeedId } else { '' }

    Sql @"
BEGIN;
DELETE FROM AuditLog $clause;
INSERT INTO AuditLog (FeedId, TimestampUtc, UserName, Action, ItemId, Summary)
VALUES ('$feedSql', '$now', '$whoSql', 'Purge', NULL, '$summarySql');
COMMIT;
"@
    Say "  Deleted $affected entries"
    Say "  Purge recorded in the log by $who" 'Green'

    Sql "VACUUM;"
    Say "  VACUUM complete - freed pages reclaimed"

    # ---------------------------------------------------------------- 8. verify
    Mark 'Step 8 - verify'

    $after = [int](Sql "SELECT COUNT(*) FROM AuditLog;")
    Say "  Entries before : $total"
    Say "  Entries after  : $after  (expected $($keep + 1), including the purge record)"
    if ($after -ne $keep + 1) { Say "  UNEXPECTED COUNT - review before restarting" 'Red' }
    else                      { Say "  Count correct" 'Green' }

    Say "`n  Integrity check: $(Sql 'PRAGMA integrity_check;')"
    Say ("  Database size  : {0:N0} bytes" -f (Get-Item $dbPath).Length)

    # ---------------------------------------------------------------- 9. restart
    Mark 'Step 9 - restart and smoke test'
    & $appcmdExe start apppool /apppool.name:$AppPoolName
    $script:poolStopped = $false
    Start-Sleep -Seconds 3
    Say "  App pool state: $(& $appcmdExe list apppool $AppPoolName /text:state)"

    try {
        $url = 'https://swpapp-digisign.swp-rest.police.int/signageadmin/Audit'
        $r = Invoke-WebRequest -Uri $url -UseDefaultCredentials -UseBasicParsing -TimeoutSec 30
        Say "  GET $url -> HTTP $($r.StatusCode)" 'Green'
    } catch {
        Say "  Smoke test failed: $($_.Exception.Message)" 'Red'
        Say "  Check the site manually before handing over." 'Red'
    }

    Mark 'Done'
    Say "  Backup : $backup"
    Say "  Archive: $csv"
    Say "  Keep both. They are the record of what was removed." 'Yellow'
}
catch {
    Say "`nFAILED: $($_.Exception.Message)" 'Red'

    if ($script:poolStopped) {
        Say "`nApp pool was stopped by this run - restarting it so the site is not left down." 'Yellow'
        try {
            $exe = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
            & $exe start apppool /apppool.name:$AppPoolName | Out-Null
            Start-Sleep -Seconds 2
            Say "  App pool state: $(& $exe list apppool $AppPoolName /text:state)" 'Green'
        } catch {
            Say "  COULD NOT RESTART THE APP POOL - start it manually:" 'Red'
            Say "    appcmd start apppool /apppool.name:$AppPoolName" 'Red'
        }
    }

    Say "`nThe database backup and CSV archive, if taken, are in $WorkDir" 'Yellow'
    Say "The database itself is unchanged unless Step 7 reported a deletion." 'Yellow'
    throw
}
finally {
    Stop-Transcript | Out-Null
}
