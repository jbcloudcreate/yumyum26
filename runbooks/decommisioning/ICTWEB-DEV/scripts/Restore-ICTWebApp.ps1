<#
    SWPDEV-ICTWEB - restore a stopped site or application

    Someone has shouted. Put what they told you into $target, run it once to
    preview, then set $Commit = $true and run it again.

    $target accepts any of these:
        'ucdashboard'
        '/ucdashboard'
        'http://swpdev-ictweb/ucdashboard'
        'ADLockoutsSD/ADLockout'
        'Signagefeedadmin'              (one of the standalone sites)
        '/'                             (the server home page)

    Read-only until $Commit is $true. Nothing is deleted at any point.
#>

# =====================================================================
$target = 'ucdashboard'        # <-- what they said is broken
$Commit = $false               # <-- $false previews, $true restores
# =====================================================================


$ErrorActionPreference = 'Stop'
$appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
Import-Module WebAdministration -ErrorAction SilentlyContinue

if ($env:COMPUTERNAME -ne 'SWPDEV-ICTWEB') {
    throw "WRONG SERVER. This is $env:COMPUTERNAME. Stop here."
}

# Start a transcript so the restore is evidenced like everything else
if ($Commit) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $log   = "C:\temp\ICTWebDecomm\transcripts\restore-$stamp.log"
    New-Item (Split-Path $log) -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $log -IncludeInvocationHeader | Out-Null
    "=== Restore request: '$target' ==="
    "Operator : $env:USERDOMAIN\$env:USERNAME"
    "Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

function Test-Url([string]$Url) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect     = $false
    $req.UseDefaultCredentials = $true
    $req.Timeout               = 15000
    $resp = $null; $err = $null
    try   { $resp = $req.GetResponse() }
    catch [System.Net.WebException] { $err = $_.Exception.Status; $resp = $_.Exception.Response }
    if ($resp) {
        [pscustomobject]@{ Url=$Url; Status=[int]$resp.StatusCode; Note=$err }
        $resp.Close()
    } else {
        [pscustomobject]@{ Url=$Url; Status='ERROR'; Note=$err }
    }
}

# ---------- build an inventory from appcmd ----------

$apps = & $appcmd list app | ForEach-Object {
    if ($_ -match '^APP "([^"]+)"\s+\(applicationPool:(.+)\)\s*$') {
        [pscustomobject]@{ AppPath = $Matches[1]; Pool = $Matches[2] }
    }
}

$sites = & $appcmd list site | ForEach-Object {
    if ($_ -match '^SITE "([^"]+)"\s+\(id:(\d+),bindings:(.+),state:(\w+)\)\s*$') {
        [pscustomobject]@{ Site = $Matches[1]; Bindings = $Matches[3]; State = $Matches[4] }
    }
}

# ---------- work out what they actually meant ----------

$needle = $target -replace '^https?://[^/]+', ''
$needle = $needle -replace '^\s*Default Web Site\s*', ''
$needle = $needle.Trim().Trim('/')
$isRoot = [string]::IsNullOrWhiteSpace($needle)

$matchedApps = @()
$matchedSite = $null

if ($isRoot) {
    $matchedApps = @($apps | Where-Object { $_.AppPath -eq 'Default Web Site/' })
} else {
    $matchedApps = @($apps | Where-Object { $_.AppPath -like "*/$needle" })
    $matchedSite = $sites | Where-Object { $_.Site -eq $needle }
    if ($matchedSite) {
        $matchedApps += @($apps | Where-Object { $_.AppPath -eq ($matchedSite.Site + '/') })
    }
}

if (-not $matchedApps -and -not $matchedSite) {
    ""
    "No match for '$target'."
    ""
    "Applications on this server:"
    $apps | Sort-Object AppPath | Format-Table AppPath, Pool -AutoSize
    "Sites on this server:"
    $sites | Format-Table Site, State, Bindings -AutoSize
    if ($Commit) { Stop-Transcript | Out-Null }
    return
}

# ---------- what has to start, and what comes with it ----------

$poolsNeeded = @($matchedApps.Pool) | Where-Object { $_ } | Sort-Object -Unique
$collateral  = @($apps | Where-Object { $poolsNeeded -contains $_.Pool })

if ($poolsNeeded -contains 'quicklinks') {
    throw "That resolves to the quicklinks pool, which is deliberately still running. Nothing to restore."
}

""
"================= RESTORE PLAN ================="
"Requested          : $target"
"Resolved to        : $(($matchedApps.AppPath) -join ', ')"
if ($matchedSite) { "Site to start      : $($matchedSite.Site)  (currently $($matchedSite.State))" }
"App pool(s)        : $($poolsNeeded -join ', ')"
""

if ($collateral.Count -gt $matchedApps.Count) {
    "*** THIS ALSO BRINGS BACK ***"
    $collateral |
        Where-Object { $matchedApps.AppPath -notcontains $_.AppPath } |
        ForEach-Object { "    $($_.AppPath)   (shares pool '$($_.Pool)')" }
    ""
    "These share an application pool with what you asked for. There is no way"
    "to start one without the others. Check nobody minds before committing."
    ""
}

"--- current state ---"
foreach ($p in $poolsNeeded) {
    "{0,-24} {1,-9} autoStart={2}" -f $p,
        (Get-WebAppPoolState -Name $p).Value,
        (Get-Item "IIS:\AppPools\$p").autoStart
}
""

if (-not $Commit) {
    "PREVIEW ONLY - nothing changed."
    "Set `$Commit = `$true and run again to restore."
    "================================================"
    return
}

# ---------- do it ----------

""
"--- restoring ---"

foreach ($p in $poolsNeeded) {
    Set-ItemProperty "IIS:\AppPools\$p" -Name autoStart -Value $true
    if ((Get-WebAppPoolState -Name $p).Value -ne 'Started') {
        Start-WebAppPool -Name $p
    }
    # Poll rather than guess - a pool can sit in Starting for a few seconds
    $waited = 0
    while ((Get-WebAppPoolState -Name $p).Value -ne 'Started' -and $waited -lt 20) {
        Start-Sleep -Milliseconds 500; $waited++
    }
    "{0,-24} {1,-9} autoStart={2}" -f $p,
        (Get-WebAppPoolState -Name $p).Value,
        (Get-Item "IIS:\AppPools\$p").autoStart
}

if ($matchedSite -and $matchedSite.State -ne 'Started') {
    Set-ItemProperty "IIS:\Sites\$($matchedSite.Site)" -Name serverAutoStart -Value $true
    Start-Website -Name $matchedSite.Site
    Start-Sleep -Seconds 2
    "Site $($matchedSite.Site) : $((Get-Website -Name $matchedSite.Site).State)"
}

# ---------- prove it ----------

""
"--- verification ---"

if ($matchedSite) {
    $port = ($matchedSite.Bindings -split ':')[1]
    "Test manually in a browser: http://swpdev-ictweb`:$port/"
} else {
    $path = if ($isRoot) { '/' } else { "/$needle/" }
    Test-Url "http://swpdev-ictweb$path" | Format-Table -AutoSize
    "Anything other than 200 or 302 means it started but the application itself is unhappy."
}

""
"--- QuickLinks redirect must be unaffected ---"
Test-Url 'http://swpdev-ictweb/quicklinks/' | Format-Table -AutoSize
"(expect 302)"
""
"Restored : $target"
"By       : $env:USERDOMAIN\$env:USERNAME"
"At       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
"================================================"

Stop-Transcript | Out-Null
