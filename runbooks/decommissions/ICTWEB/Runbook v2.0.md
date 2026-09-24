# SWPDEV-ICTWEB — Site Shutdown, QuickLinks Redirect and Scheduled Decommission

**Runbook version:** 2.0 — consolidated
**Supersedes:** v1.0, v1.1, Redirect Remediation v1.0, Phase 1 Completion
**Target server:** `SWPDEV-ICTWEB` · 10.20.253.127 · Windows Server 2016 (10.0.14393) · IIS 10.0 · PowerShell 5.1.14393.9507
**Executed:** 24 September 2026 by `SWP-NET\SWP59639a`
**Change reference:** _&lt;fill in&gt;_

| Phase | Outcome | Status |
|---|---|---|
| **Phase 1** | Survey sites, stop everything except QuickLinks, redirect QuickLinks to its new home | ✅ Complete, 24 Sep 14:31 |
| **Phase 2** | Scheduled shutdown two weeks out | ⬜ Not started |

This document replaces all earlier versions. Everything learned during execution is folded in — anyone picking this up needs nothing else.

---

## 1. Execution record

### Timeline

| Time | Event |
|---|---|
| 13:35 | Session opened, server and elevation guards passed |
| 13:36 | Survey. `Web-Http-Redirect` was `Available`, installed |
| 13:38 | uctools returned 401 — unauthenticated check, inconclusive. Session paused |
| 13:57 | Resumed. uctools authenticated: **HTTP 200, title "Quicklinks"** |
| 13:58 | QuickLinks resolved to `E:\webroot\quicklinks`, no existing `httpRedirect` in its web.config |
| 14:01 | Backup taken — `predecomm-20260924-1335`, applicationHost.config 87,859 bytes |
| 14:02 | Redirect applied, then switched to the sub-path variant. **Test Gate 3 failed** — doubled paths |
| 14:04 | Failure recorded in transcript. Session paused |
| 14:13 | Resumed. uctools confirmed **not** to serve sub-paths — `/quicklinks/home` returns 404 |
| 14:15 | Config A applied (fixed destination) |
| 14:17 | **Test Gate 3R passed** — 302 on all paths, end-to-end 200 |
| 14:17 | HTTPS binding diagnosed: dangling certificate, pre-existing |
| 14:19 | Pool stop loop skipped. **Test Gate 4 caught it** — `/ucdashboard/` returned 200, not 503 |
| 14:29 | Resumed. Stop loop completed, DefaultAppPool autoStart corrected |
| 14:30 | **Test Gate 4C passed** — all five paths 503, QuickLinks 302 |
| 14:31 | Closing record captured. Transcript stopped 14:33 |

Two gates failed and both were caught by the gate rather than by a user. That is the process working.

### Evidence

| Artefact | Location |
|---|---|
| Transcript | `C:\temp\ICTWebDecomm\transcripts\ictweb-decomm-20260924-1335.log` |
| IIS backup set | `predecomm-20260924-1335` |
| applicationHost.config | `C:\temp\ICTWebDecomm\backup\applicationHost.config.20260924-1335.bak` (87,859 bytes) |
| QuickLinks web.config | `C:\temp\ICTWebDecomm\backup\quicklinks-web.config.20260924-1335.bak` |
| Pre-change state | `C:\temp\ICTWebDecomm\state\{sites,apppools,apps}-before-20260924-1335.csv` |

---

## 2. Server as found

### Sites — only one was active

| Site | Id | State at survey | Bindings |
|---|---|---|---|
| `Default Web Site` | 1 | **Started** | `http/*:80:`, `https/*:443:` |
| `Signagefeedadmin` | 2 | Stopped | `http/*:8081:` |
| `SWPICTSignageFeedHub` | 3 | Stopped | `http/*:8082:` |

That single line answers "list what websites are active in IIS" for the change record.

### Applications — all under Default Web Site

| Application | Pool | Disposition |
|---|---|---|
| `/` (site root) | `DefaultAppPool` | Stopped |
| `/ud` | `ud` | Stopped |
| **`/quicklinks`** | **`quicklinks`** | **Kept running — serves the redirect** |
| `/ucdashboard` | `ucdashboard` | Stopped |
| `/etsdashboard` | `etsdashboard` | Stopped |
| `/UserManagement` | `UserManagement` | Stopped |
| `/chatbot` | `chatbot` | Stopped |
| `/iistest` | `iistest` | Stopped |
| `/wac` | `DefaultAppPool` | Stopped with the site root |
| `/ADLockoutsSD/ADLockout` | `DefaultAppPool` | Stopped with the site root |
| `/IL3_checks_Dev` | `IL3_Checks_Dev` | Stopped |
| `/feedhub` | `SWPICTHub` | Already stopped before the change |
| `/signageadmin` | `SignageAdminApp` | Already stopped before the change |

**QuickLinks is an application, not a site.** `Default Web Site` therefore had to stay Started throughout — stopping it would have taken QuickLinks with it. The work was stopping *application pools*, not sites.

**Three applications share `DefaultAppPool`.** There is no way to stop one without the other two. Option A was chosen: all three down.

### QuickLinks detail

| | |
|---|---|
| Path | `Default Web Site/quicklinks` |
| Physical path | `E:\webroot\quicklinks` |
| App pool | `quicklinks` (No Managed Code) |
| Application type | PowerShell Universal Dashboard (`universaldashboard.server.exe` via `AspNetCoreModule`) |
| Existing web.config | Present, dated 02/07/2020, **no** `httpRedirect` element |

### Redirect target

| | |
|---|---|
| URL | `https://uctools/quicklinks/` |
| Resolves to | `uctools.swp-rest.police.int` → 10.20.243.195 |
| This server | 10.20.253.127 — **different host, no loop** |
| Authenticated response | HTTP 200, 1158 bytes, title "Quicklinks" |
| Sub-paths | **404** — `/quicklinks/home` and `/quicklinks/nonsense-path-test` both fail |
| Certificate | Valid for the short name `uctools` — TLS handshake succeeded from this server |

The 404 on sub-paths is what drove the choice of redirect configuration. See Part 3.

---

## 3. Part 0 — Transcript and helpers

Run first, in the elevated session used for the whole change.

```powershell
$workRoot = "C:\temp\ICTWebDecomm"
$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
mkdir "$workRoot\transcripts" -Force | Out-Null
mkdir "$workRoot\backup"      -Force | Out-Null
mkdir "$workRoot\state"       -Force | Out-Null

$transcript = "$workRoot\transcripts\ictweb-decomm-$stamp.log"
Start-Transcript -Path $transcript -IncludeInvocationHeader

"=== SWPDEV-ICTWEB - site shutdown and scheduled decommission ==="
"Runbook version : 2.0"
"Change ref      : <fill in>"
"Server          : $env:COMPUTERNAME"
"Operator        : $env:USERDOMAIN\$env:USERNAME"
"Started         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
"Transcript      : $transcript"
"==============================================================="
```

Keep this session open. `$workRoot`, `$stamp` and `$transcript` are referenced throughout.

### Stage marker

**Note the quotes** — `Mark "Part 1 - survey"`, not `Mark Part 1 - survey`. Without them PowerShell passes only the first word.

```powershell
function Mark([string]$text) {
    ""
    "########## $text  [$(Get-Date -Format 'HH:mm:ss')] ##########"
    ""
}
```

### HTTP test helper

`Invoke-WebRequest -MaximumRedirection 0` behaves inconsistently on PowerShell 5.1 — sometimes it returns the 302, sometimes it throws. This goes straight to `HttpWebRequest` so the result is deterministic, sends your credentials so Windows-auth sites answer properly, and surfaces the underlying `WebExceptionStatus` when there is no response at all.

```powershell
function Test-Redirect([string]$Url) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect     = $false
    $req.UseDefaultCredentials = $true
    $req.Timeout               = 15000
    $resp = $null; $err = $null
    try   { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $err  = $_.Exception.Status
        $resp = $_.Exception.Response
    }
    if ($resp) {
        [pscustomobject]@{
            Url      = $Url
            Status   = [int]$resp.StatusCode
            Location = $resp.Headers['Location']
            Note     = $err
        }
        $resp.Close()
    } else {
        [pscustomobject]@{ Url = $Url; Status = 'ERROR'; Location = $null; Note = $err }
    }
}
```

### Guards

```powershell
Mark "Part 0 - guards"

if ($env:COMPUTERNAME -ne 'SWPDEV-ICTWEB') {
    throw "WRONG SERVER. This is $env:COMPUTERNAME. Stop here."
}
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Not elevated. Reopen PowerShell as Administrator." }
"Guards passed - $env:COMPUTERNAME, $env:USERNAME"
```

### Shared variables

```powershell
$appcmd     = "$env:windir\system32\inetsrv\appcmd.exe"
$apphost    = 'MACHINE/WEBROOT/APPHOST'
$filter     = '/system.webServer/httpRedirect'
$qlApp      = 'Default Web Site/quicklinks'
$redirectTo = 'https://uctools/quicklinks/'
Import-Module WebAdministration
```

### Resuming after a break

Append to the same file rather than starting a second one, and re-declare everything above — none of it survives a session close.

```powershell
$stamp      = '<the ORIGINAL stamp>'
$transcript = "C:\temp\ICTWebDecomm\transcripts\ictweb-decomm-$stamp.log"
Start-Transcript -Path $transcript -Append -IncludeInvocationHeader
"=== Resumed $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') at Part <n> ==="
```

---

## 4. Part 1 — Survey

```powershell
Mark "Part 1 - survey"

"--- Sites ---"
& $appcmd list site
"--- Applications ---"
& $appcmd list app
"--- App pools ---"
& $appcmd list apppool

"--- Sites (provider view) ---"
Get-Website | Select-Object Name, Id, State, PhysicalPath,
    @{n='Bindings';e={ ($_.bindings.Collection | ForEach-Object { "$($_.protocol)/$($_.bindingInformation)" }) -join '; ' }},
    applicationPool | Format-Table -AutoSize
```

> If the provider returns nothing but `appcmd` lists sites, use `appcmd` for enumeration and the `Set-WebConfiguration*` cmdlets for changes. That happened on `swpapp-digisign`; it did not happen here, but it is a known behaviour on these builds.

### Locate the target application

```powershell
& $appcmd list site | Select-String -Pattern 'quicklink' -SimpleMatch
& $appcmd list app  | Select-String -Pattern 'quicklink' -SimpleMatch

Get-WebApplication -Site 'Default Web Site' -Name 'quicklinks' |
    Select-Object Path, PhysicalPath, ApplicationPool, EnabledProtocols | Format-List

$qlPhysical  = [Environment]::ExpandEnvironmentVariables(
                 (Get-WebApplication -Site 'Default Web Site' -Name 'quicklinks').PhysicalPath)
$qlWebConfig = Join-Path $qlPhysical 'web.config'

"Physical path : $qlPhysical"
"web.config    : $(Test-Path $qlWebConfig)"
if (Test-Path $qlWebConfig) { Get-Content $qlWebConfig -Raw }
```

If that `web.config` already contains an `<httpRedirect>` element it will **override** anything set at `applicationHost.config` scope, and Part 3 will appear to succeed while changing nothing. Check before proceeding.

### HTTP Redirection feature

The redirect silently fails without it.

```powershell
Get-WindowsFeature Web-Http-Redirect | Select-Object Name, InstallState
# If not Installed:
Install-WindowsFeature Web-Http-Redirect
```

No restart needed, but it briefly recycles the web service. **Do this before Part 2** so the backup includes the module — otherwise a config restore removes a module that other config references.

### Verify the redirect target properly

Three separate things to establish. Skipping any one of them is how the first attempt went wrong.

```powershell
Mark "Part 1 - redirect target checks"

# 1. No loop
Resolve-DnsName uctools -ErrorAction SilentlyContinue | Select-Object Name, IPAddress
Get-NetIPAddress | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object IPAddress

# 2. The target actually serves content - AUTHENTICATED
try {
    $r = Invoke-WebRequest -Uri $redirectTo -UseBasicParsing -UseDefaultCredentials -TimeoutSec 15 -ErrorAction Stop
    "Target returned HTTP $($r.StatusCode), $($r.RawContentLength) bytes"
    "Title: $(([regex]::Match($r.Content,'(?is)<title>(.*?)</title>')).Groups[1].Value.Trim())"
} catch {
    "FAILED: $($_.Exception.Message)"
    if ($_.Exception.Response) { "Status: $([int]$_.Exception.Response.StatusCode)" }
}

# 3. Does it serve sub-paths? This decides the redirect configuration.
foreach ($p in @('/quicklinks/', '/quicklinks/home', '/quicklinks/nonsense-path-test')) {
    $u = "https://uctools$p"
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -UseDefaultCredentials -TimeoutSec 15 -ErrorAction Stop
        "{0,-45} {1}  ({2} bytes)" -f $u, $r.StatusCode, $r.RawContentLength
    } catch {
        $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'no response' }
        "{0,-45} {1}" -f $u, $sc
    }
}
```

**`-UseDefaultCredentials` is not optional.** Without it, a Windows-auth site returns 401 before it resolves the path — a response identical to what you would get for a URL that does not exist. The first attempt on this server hit exactly that and learned nothing from it.

Reading the sub-path result:

| `/quicklinks/home` | `/nonsense-path-test` | Meaning | Configuration |
|---|---|---|---|
| 200 | 200 | SPA — every path returns the shell | **Config B** |
| 200 | 404 | Real server-side routes | **Config B** |
| 404 | 404 | Sub-paths not served | **Config A** |

**On SWPDEV-ICTWEB: 200 / 404 / 404 → Config A.**

### ▣ TEST GATE 1

```powershell
Mark "TEST GATE 1 - survey findings"

"Target authenticated status     : 200"
"Target serves sub-paths         : No - Config A"
"QuickLinks is                   : APPLICATION Default Web Site/quicklinks"
"QuickLinks physical path        : E:\webroot\quicklinks"
"Existing web.config httpRedirect: No"
"Sites to stop                   : none - both non-default sites already Stopped"
"Pools to stop                   : ud, ucdashboard, etsdashboard, UserManagement, chatbot, iistest, IL3_Checks_Dev"
"Idle pools to secure            : Signagefeedadmin, SWPICTSignageFeedHub, SWPICTHub, SignageAdminApp"
"DefaultAppPool decision         : Option A - stop (takes /, /wac, /ADLockoutsSD/ADLockout)"
"Owner confirmed /wac            : <name>"
"Owner confirmed /ADLockoutsSD   : <name>"
"TEST GATE 1 - PASSED"
```

> **`/wac` and `/ADLockoutsSD/ADLockout` deserve a real answer, not a quick one.** Windows Admin Center and an AD lockout tool both sound like things someone outside the team may have bookmarked, despite living on a dev box. If either has users, choose Option B and leave `DefaultAppPool` running.

---

## 5. Part 2 — Backup

```powershell
Mark "Part 2 - backup"

Copy-Item "$env:windir\system32\inetsrv\config\applicationHost.config" `
          "$workRoot\backup\applicationHost.config.$stamp.bak" -Force

if (Test-Path $qlWebConfig) {
    Copy-Item $qlWebConfig "$workRoot\backup\quicklinks-web.config.$stamp.bak" -Force
}

& $appcmd add backup "predecomm-$stamp"

Get-Website | Select-Object Name, Id, State, PhysicalPath, applicationPool, serverAutoStart |
    Export-Csv "$workRoot\state\sites-before-$stamp.csv" -NoTypeInformation

Get-ChildItem IIS:\AppPools | ForEach-Object {
    [pscustomobject]@{
        Name      = $_.Name
        State     = (Get-WebAppPoolState -Name $_.Name -ErrorAction SilentlyContinue).Value
        AutoStart = $_.autoStart
    }
} | Export-Csv "$workRoot\state\apppools-before-$stamp.csv" -NoTypeInformation

Get-WebApplication | Select-Object Path, PhysicalPath, ApplicationPool |
    Export-Csv "$workRoot\state\apps-before-$stamp.csv" -NoTypeInformation

"--- Backup contents ---"
Get-ChildItem "$workRoot\backup", "$workRoot\state"
& $appcmd list backup
```

> The app pool CSV now captures `AutoStart` as well as `State`. v1.1 captured only state, which made a faithful rollback impossible for pools whose autoStart was changed.

### ▣ TEST GATE 2

```powershell
Mark "TEST GATE 2 - backup verified"
$bk = "$workRoot\backup\applicationHost.config.$stamp.bak"
"Exists : $(Test-Path $bk)"
"Bytes  : $((Get-Item $bk).Length)"
Import-Csv "$workRoot\state\apppools-before-$stamp.csv" | Measure-Object | Select-Object Count
"TEST GATE 2 - PASSED"
```

---

## 6. Part 3 — The QuickLinks redirect

Apply the redirect **before** stopping anything else. If it misbehaves you are troubleshooting one change, not two.

### Scope — commit to applicationHost.config

`httpRedirect` is a **delegated** section. `Set-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\quicklinks"` writes into the application's own `web.config` **on disk**. That puts the change outside your `applicationHost.config` backup and modifies a file inside the application.

Using `-PSPath $apphost -Location $qlApp` keeps it in `applicationHost.config`, where the backup covers it and no application file is touched.

### ⚠ exactDestination and $S — the rule that broke the first attempt

Both of these append the request's sub-path:

- `exactDestination = $true` → destination used **verbatim**. Variables (`$S`, `$Q`, `$V`, `$P`) are still substituted.
- `exactDestination = $false` → IIS **appends** the requested relative path to the destination.

**Use variables, or use auto-append. Never both.** Setting `exactDestination = $false` alongside `$S` applies the suffix twice:

| Request | `$S` | After substitution | IIS appends | Result |
|---|---|---|---|---|
| `/quicklinks/` | `/` | `…/quicklinks/` | `/` | `…/quicklinks//` ✗ |
| `/quicklinks/home` | `/home` | `…/quicklinks/home` | `/home` | `…/quicklinks/home/home` ✗ |

### Redirect type — 302, not 301

`Found` (302) is **not cached**. `Permanent` (301) **is cached by browsers, often indefinitely**, and cannot be reliably withdrawn — removing it from the server does not help, because the browser has stopped asking.

On this change the first attempt was forwarding people to a 404 for thirteen minutes. With a 302 that evaporated on fix. With a 301 it would have been cached in every browser that hit it, and the only remedy is clearing the cache on each machine.

Use `Found`. The usual argument for 301 is search-engine ranking transfer, which is irrelevant for an internal tool behind Windows auth.

### Config A — fixed destination (used here)

Every request under `/quicklinks` lands on the QuickLinks home page at the target, whatever path or query string it carried. Correct when the target does not serve sub-paths.

```powershell
Mark "Part 3 - redirect, Config A"

Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name destination        -Value 'https://uctools/quicklinks/'
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name exactDestination   -Value $true
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name childOnly          -Value $false
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name httpResponseStatus -Value 'Found'
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name enabled            -Value $true
```

### Config B — preserve sub-path and query string

Only when the target serves sub-paths. Note `exactDestination` is **`$true`** here too.

```powershell
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name destination        -Value 'https://uctools/quicklinks$S$Q'
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name exactDestination   -Value $true
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name childOnly          -Value $false
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name httpResponseStatus -Value 'Found'
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name enabled            -Value $true
```

### Confirm what landed

```powershell
Get-WebConfiguration -PSPath $apphost -Location $qlApp -Filter $filter |
    Select-Object enabled, destination, exactDestination, childOnly, httpResponseStatus

"web.config last modified: $((Get-Item $qlWebConfig).LastWriteTime)"
```

That timestamp must be unchanged from Part 1. It is how you know the change went to `applicationHost.config` and your rollback covers it.

### appcmd equivalent

```powershell
& $appcmd set config "Default Web Site/quicklinks" /section:httpRedirect `
    /enabled:true /destination:"https://uctools/quicklinks/" `
    /exactDestination:true /childOnly:false /httpResponseStatus:Found /commit:apphost
```

> The `quicklinks` application pool must stay **Started**. HTTP Redirect is a native module but runs inside the worker process — stop that pool and the redirect returns 503 instead of 302.

### ▣ TEST GATE 3

**Sub-paths and query strings, not just the root.** v1.1 tested three variants of the root only, which is exactly the case that cannot fail, and the defect reached a browser as a result.

```powershell
Mark "TEST GATE 3 - redirect verification"

@(
    'http://swpdev-ictweb/quicklinks'
    'http://swpdev-ictweb/quicklinks/'
    'http://swpdev-ictweb/quicklinks/home'
    'http://swpdev-ictweb/quicklinks/home?tab=1'
    'https://swpdev-ictweb/quicklinks/'
) | ForEach-Object { Test-Redirect $_ } | Format-Table -AutoSize
```

Config A — every line 302 to `https://uctools/quicklinks`.
Config B — path and query preserved on each.
**No doubled segments. No `//` after the hostname.**

### Follow it end to end

A correct `Location` header is necessary but not sufficient.

```powershell
Mark "TEST GATE 3 - end-to-end follow"

foreach ($u in @('http://swpdev-ictweb/quicklinks/', 'http://swpdev-ictweb/quicklinks/home')) {
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -UseDefaultCredentials -TimeoutSec 20 -ErrorAction Stop
        "{0,-42} final HTTP {1}, {2} bytes" -f $u, $r.StatusCode, $r.RawContentLength
    } catch {
        $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'no response' }
        "{0,-42} FAILED: {1}" -f $u, $sc
    }
}
```

Both must end in **HTTP 200**.

Then, **in a browser from a client machine, as a normal user**. Record who tested and from where:

```powershell
Mark "TEST GATE 3 - browser check by <name> from <machine> - PASSED"
Mark "TEST GATE 3 - PASSED"
```

### HTTPS diagnostic — record, do not block on

```powershell
Mark "Part 3 - HTTPS binding diagnostic"

netsh http show sslcert ipport=0.0.0.0:443
Get-WebBinding -Name 'Default Web Site' -Protocol https |
    Select-Object protocol, bindingInformation, certificateHash

$thumb = (Get-WebBinding -Name 'Default Web Site' -Protocol https).certificateHash
if ($thumb) {
    Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumb } |
        Select-Object Subject, NotAfter, @{n='Expired';e={$_.NotAfter -lt (Get-Date)}}, DnsNameList
} else { "No certificate hash on the https binding" }
```

**Finding on SWPDEV-ICTWEB:** certificate `953A0CC026BF34134F12ED725E8C940D102C39B8` is bound at `0.0.0.0:443`, but no matching certificate exists in `Cert:\LocalMachine\My`. The binding points at a thumbprint no longer in the store, which is why `https://swpdev-ictweb/` returns `TrustFailure`.

Pre-existing, unrelated to this change, and it disappears with the server. Worth one line in the change record so nobody attributes it to the decommission. Anyone who bookmarked the `https://` form of QuickLinks gets a certificate warning before reaching the redirect.

---

## 7. Part 4 — Stop everything except QuickLinks

`Default Web Site` stays **Started** throughout. QuickLinks lives inside it.

```powershell
Mark "Part 4 - stop application pools"

$poolsToStop = @('ud','ucdashboard','etsdashboard','UserManagement','chatbot','iistest','IL3_Checks_Dev')
$poolsIdle   = @('Signagefeedadmin','SWPICTSignageFeedHub','SWPICTHub','SignageAdminApp')

"Will STOP         : $($poolsToStop -join ', ')"
"Will SECURE       : $($poolsIdle -join ', ')"
"Will KEEP RUNNING : quicklinks"
"DefaultAppPool    : <Option A stopping | Option B leaving running>"
```

> `$poolsIdle` includes `SWPICTHub` and `SignageAdminApp`, which were already Stopped before the change. **Already stopped is not the same as will stay stopped** — they had `autoStart=True` and would have restarted on the next reboot, bringing `/feedhub` and `/signageadmin` back. v1.1 missed this.

### Dry run

```powershell
foreach ($p in ($poolsToStop + $poolsIdle)) {
    "{0,-26} currentState={1} autoStart={2}" -f $p,
        (Get-WebAppPoolState -Name $p -ErrorAction SilentlyContinue).Value,
        (Get-Item "IIS:\AppPools\$p" -ErrorAction SilentlyContinue).autoStart
}
```

A pool reporting blank does not exist under that name. Fix the list before continuing.

### Stop, with per-pool confirmation

```powershell
Mark "Part 4 - stopping"

foreach ($p in ($poolsToStop + $poolsIdle)) {
    if ($p -eq 'quicklinks') { "REFUSING to stop quicklinks"; continue }

    $before = (Get-WebAppPoolState -Name $p -ErrorAction SilentlyContinue).Value
    if ($before -ne 'Stopped') { Stop-WebAppPool -Name $p -ErrorAction Continue }

    # Poll until settled - a pool with an active worker can sit in Stopping
    $waited = 0
    while ((Get-WebAppPoolState -Name $p).Value -notin @('Stopped') -and $waited -lt 20) {
        Start-Sleep -Milliseconds 500; $waited++
    }

    Set-ItemProperty "IIS:\AppPools\$p" -Name autoStart -Value $false

    "{0,-26} {1} -> {2}  autoStart={3}" -f $p, $before,
        (Get-WebAppPoolState -Name $p).Value,
        (Get-Item "IIS:\AppPools\$p").autoStart
}
```

> Two fixes here. The loop reports `before -> after` per pool, so skipping it leaves a visible hole in the transcript — v1.1's silent loop was missed entirely on the first attempt and nothing in the log said so. And it polls rather than sleeping a fixed 400ms, which on the first run reported `ucdashboard` as `Stopping` and looked like a failure when it was not.

### DefaultAppPool

Run **or delete** this block according to your Test Gate 1 decision. It is not commented out — a load-bearing step must never depend on the operator un-commenting a line mid-paste, which is how it was missed on the first attempt.

```powershell
Mark "Part 4 - Option A - stopping DefaultAppPool"
"This stops: / (site root), /wac, /ADLockoutsSD/ADLockout"

Stop-WebAppPool -Name 'DefaultAppPool' -ErrorAction Continue
$waited = 0
while ((Get-WebAppPoolState -Name 'DefaultAppPool').Value -ne 'Stopped' -and $waited -lt 20) {
    Start-Sleep -Milliseconds 500; $waited++
}
Set-ItemProperty "IIS:\AppPools\DefaultAppPool" -Name autoStart -Value $false

"DefaultAppPool : $((Get-WebAppPoolState -Name 'DefaultAppPool').Value) / autoStart=$((Get-Item 'IIS:\AppPools\DefaultAppPool').autoStart)"
```

### Full state

```powershell
Mark "Part 4 - final pool states"

Get-ChildItem IIS:\AppPools | Sort-Object Name | ForEach-Object {
    "{0,-26} {1,-9} autoStart={2}" -f $_.Name, (Get-WebAppPoolState -Name $_.Name).Value, $_.autoStart
}
```

Expected: **`quicklinks` is the only pool reading `Started` / `autoStart=True`.**

The five unused IIS defaults (`.NET v2.0`, `.NET v2.0 Classic`, `.NET v4.5`, `.NET v4.5 Classic`, `Classic .NET AppPool`) still read Started. No application references them, so they serve nothing. Leave them — stopping them is cosmetic and adds rollback surface for no benefit.

### ▣ TEST GATE 4

```powershell
Mark "TEST GATE 4 - post-stop verification"

"--- Default Web Site MUST still be Started ---"
Get-Website | Select-Object Name, State | Format-Table -AutoSize

"--- QuickLinks must still redirect ---"
Test-Redirect 'http://swpdev-ictweb/quicklinks/'

"--- Stopped applications must now return 503 ---"
@(
    'http://swpdev-ictweb/ucdashboard/'
    'http://swpdev-ictweb/etsdashboard/'
    'http://swpdev-ictweb/chatbot/'
    'http://swpdev-ictweb/UserManagement/'
    'http://swpdev-ictweb/'
) | ForEach-Object { Test-Redirect $_ } | Format-Table -AutoSize
```

| Check | Required | Result 24 Sep |
|---|---|---|
| `Default Web Site` | Started | ✅ |
| `/quicklinks/` | 302 → uctools | ✅ |
| `/ucdashboard/` | 503 | ✅ |
| `/etsdashboard/` | 503 | ✅ |
| `/chatbot/` | 503 | ✅ |
| `/UserManagement/` | 503 | ✅ |
| `/` (site root) | 503 | ✅ |

A 200 on any of the bottom five means that pool did not stop. **Do not mark the gate passed.**

```powershell
Mark "TEST GATE 4 - PASSED"
```

**Phase 1 ends here.** Pause before Phase 2 — the observation window starts when these pools stop, not when the change record was opened.

---

## 8. Part 5 — Phase 2: schedule the shutdown ⬜

**Not yet executed.**

Two weeks from execution is **Wednesday 8 October 2026**. Midweek, mid-evening, so someone is around the next morning.

```powershell
Mark "Part 5 - schedule decommission shutdown"

$shutdownAt = Get-Date '2026-10-08 20:00:00'
$taskName   = 'Decommission - Scheduled Shutdown'
$taskPath   = '\SWP-Decomm\'
$changeRef  = '<CHG reference>'

"Shutdown scheduled for: $($shutdownAt.ToString('dddd dd MMMM yyyy HH:mm'))"
"That is $([math]::Round(($shutdownAt - (Get-Date)).TotalDays,1)) days from now"
```

```powershell
$action = New-ScheduledTaskAction -Execute 'shutdown.exe' `
    -Argument "/s /t 300 /c `"Planned decommissioning shutdown - $changeRef`" /d p:2:4"

$trigger = New-ScheduledTaskTrigger -Once -At $shutdownAt

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Powers off $env:COMPUTERNAME as part of planned decommissioning. Raised under $changeRef. Remove this task if the decommission is cancelled."
```

- `/s` powers off; it does not restart
- `/t 300` gives five minutes' warning, so anyone logged on sees a notice and the event log records intent
- `/d p:2:4` stamps it **planned, operating system, reconfiguration** — this is what makes the outage obviously deliberate afterwards
- `-StartWhenAvailable` fires at the next opportunity if the server happens to be off at 20:00, rather than skipping

### Optional — 24-hour warning

```powershell
$warnAt = $shutdownAt.AddDays(-1)
$warnAction = New-ScheduledTaskAction -Execute 'msg.exe' `
    -Argument "* /TIME:3600 This server is scheduled for permanent shutdown at $($shutdownAt.ToString('HH:mm on dd MMM yyyy')). Contact ICT Datacenter if this is unexpected."

Register-ScheduledTask -TaskName 'Decommission - 24h Warning' -TaskPath $taskPath `
    -Action $warnAction -Trigger (New-ScheduledTaskTrigger -Once -At $warnAt) `
    -Principal $principal -Settings $settings `
    -Description "Advance notice before scheduled decommissioning shutdown. $changeRef"
```

### ▣ TEST GATE 5

```powershell
Mark "TEST GATE 5 - scheduled task verification"

$t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
$i = $t | Get-ScheduledTaskInfo

"Task     : $($t.TaskName)"
"State    : $($t.State)"                 # must be Ready, not Disabled
"Runs as  : $($t.Principal.UserId)"
"Next run : $($i.NextRunTime)"           # must be 08/10/2026 20:00
"Action   : $($t.Actions.Execute) $($t.Actions.Arguments)"
```

A `NextRunTime` that is blank or in the past means the trigger did not take.

> **Do not test this task by running it.** `Start-ScheduledTask` on this one powers the server off.

```powershell
Mark "TEST GATE 5 - PASSED"
```

---

## 9. Part 6 — Tell the platform, not just the server

The task powers the guest off. Nothing stops something else powering it back on.

- [ ] Virtualisation team notified — VM must not auto-start; HA/DRS restart policy checked
- [ ] Monitoring suppressed, or the host removed from the monitored set
- [ ] Backup schedule reviewed — decide whether the final backup is retained, and for how long
- [ ] Owners of `/wac` and `/ADLockoutsSD/ADLockout` informed
- [ ] Users told to re-bookmark `https://uctools/quicklinks/` — **the redirect dies with the server**
- [ ] Change record updated with the shutdown date, the active-sites list, and the transcript attached

> The redirect is a two-week grace period for stale bookmarks, not a permanent fix. After 8 October an old bookmark is simply a dead link.

---

## 10. Part 7 — Close the transcript

Run this as one block, **read the output**, then run `Stop-Transcript` as a **separate command**.

```powershell
Mark "Session ending"

"--- Final state ---"
& $appcmd list site
& $appcmd list app
& $appcmd list apppool
Get-ChildItem IIS:\AppPools | Sort-Object Name | ForEach-Object {
    "{0,-26} {1,-9} autoStart={2}" -f $_.Name, (Get-WebAppPoolState -Name $_.Name).Value, $_.autoStart
} | Out-String
Test-Redirect 'http://swpdev-ictweb/quicklinks/' | Format-Table -AutoSize | Out-String
Get-ScheduledTask -TaskPath '\SWP-Decomm\' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize | Out-String

"Change ref         : <fill in>"
"Phase 1 outcome    : <completed | partially completed | backed out>"
"Phase 2 outcome    : <completed | not attempted>"
"DefaultAppPool     : <Option A stopped | Option B left running>"
"Redirect config    : <Config A fixed | Config B preserve sub-path> - <why>"
"Deviations         : <anything that differed from this runbook, with times>"
"Ended              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
```

```powershell
Stop-Transcript
```

> Two fixes. `Stop-Transcript` in the same pasted block truncates the record — native output (`appcmd`) writes straight through, but PowerShell's object formatter buffers, so the close happens before the tail flushes. And `| Out-String` on each formatted command forces a flush before the next line runs.
>
> **Fill in the outcome lines before stopping.** They are the first thing anyone reads. On the 24 September run, `Phase 2 outcome` and one timestamp were left as placeholders.

---

## 11. Part 8 — Rollback

### Cancel the shutdown — do this first if anything is wrong

```powershell
Unregister-ScheduledTask -TaskName 'Decommission - Scheduled Shutdown' -TaskPath '\SWP-Decomm\' -Confirm:$false
Unregister-ScheduledTask -TaskName 'Decommission - 24h Warning'        -TaskPath '\SWP-Decomm\' -Confirm:$false -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskPath '\SWP-Decomm\' -ErrorAction SilentlyContinue
```

If it has already fired, power the VM back on from vCenter. Nothing was deleted.

### Remove the redirect

```powershell
Set-WebConfigurationProperty -PSPath $apphost -Location $qlApp -Filter $filter -Name enabled -Value $false
Get-WebConfiguration -PSPath $apphost -Location $qlApp -Filter $filter | Select-Object enabled, destination
Test-Redirect 'http://swpdev-ictweb/quicklinks/'    # should no longer be 302
```

### Restore a single application

Someone shouts about one thing. Use `Restore-ICTWebApp.ps1` (Appendix A) rather than doing it by hand — it resolves the name to a pool, warns when other applications share that pool, and verifies afterwards.

### Restore everything

```powershell
Import-Csv "$workRoot\state\apppools-before-$stamp.csv" | ForEach-Object {
    if ($_.AutoStart -eq 'True') {
        Set-ItemProperty "IIS:\AppPools\$($_.Name)" -Name autoStart -Value $true
    }
    if ($_.State -eq 'Started') {
        "Starting pool $($_.Name) ..."
        Start-WebAppPool -Name $_.Name -ErrorAction Continue
    }
}

Start-Sleep -Seconds 3
Get-ChildItem IIS:\AppPools | Sort-Object Name | ForEach-Object {
    "{0,-26} {1,-9} autoStart={2}" -f $_.Name, (Get-WebAppPoolState -Name $_.Name).Value, $_.autoStart
}
```

Because the CSV records the pre-change state, `SWPICTHub` and `SignageAdminApp` correctly stay stopped — they were already stopped when it was taken.

### Full configuration restore — last resort

```powershell
& $appcmd list backup
& $appcmd restore backup "predecomm-20260924-1335"
iisreset
```

Or manually, IIS stopped first:

```powershell
iisreset /stop
Copy-Item "$workRoot\backup\applicationHost.config.$stamp.bak" `
          "$env:windir\system32\inetsrv\config\applicationHost.config" -Force
iisreset /start
```

---

## Appendix A — Restoring an application on request

`Restore-ICTWebApp.ps1` handles the "someone shouted" case. Set two variables at the top:

```powershell
$target = 'ucdashboard'        # app path, URL or site name - any form
$Commit = $false               # $false previews, $true restores
```

It resolves the name against `appcmd`, so you do not need to know which pool serves what. It accepts `ucdashboard`, `/ucdashboard`, `http://swpdev-ictweb/ucdashboard`, `ADLockoutsSD/ADLockout`, a standalone site name, or `/` for the site root.

The preview prints a `*** THIS ALSO BRINGS BACK ***` block when other applications share the pool — which they do for anything on `DefaultAppPool`. It refuses to run on the wrong server, refuses to touch the `quicklinks` pool, starts its own transcript when committing, polls until the pool settles, and re-checks the QuickLinks redirect afterwards.

> A restore sets `autoStart` back to `True`, so the application survives a reboot — correct for a genuine "we still need this", but it puts that application outside the decommission plan. Record it, or the server goes off on 8 October with something live on it that someone depends on.

---

## Appendix B — Defects found during execution

All fixed in this version. Carry them forward to the next server.

| # | Defect | Fix |
|---|---|---|
| 1 | `exactDestination = $false` combined with `$S` doubles the sub-path | Never both. Config A and B both use `$true` |
| 2 | Test Gate 3 tested root paths only | Sub-path and query string tested, plus end-to-end follow to 200 |
| 3 | `DefaultAppPool` autoStart line was behind a comment marker and got missed | Real block, run or delete |
| 4 | Stop loop ran silently, so skipping it left no trace | Reports `before -> after` per pool |
| 5 | `Stop-Transcript` in the same block truncated the closing record | Separate command, `\| Out-String` on formatted output |
| 6 | No check whether the redirect target serves sub-paths | Added to Part 1, drives the Config A/B choice |
| 7 | Already-stopped pools kept `autoStart=True` and would return on reboot | `$poolsIdle` includes them |
| 8 | Fixed 400ms sleep reported a settling pool as `Stopping` | Polls until settled |
| 9 | Unauthenticated target check returned 401 and proved nothing | `-UseDefaultCredentials` throughout |
| 10 | App pool CSV captured state but not autoStart | Both captured, rollback restores both |

---

## Quick reference

| Item | Value |
|---|---|
| Server | `SWPDEV-ICTWEB` · 10.20.253.127 |
| OS / IIS / PS | Server 2016 10.0.14393 · IIS 10.0 · PowerShell 5.1 |
| Working folder | `C:\temp\ICTWebDecomm` |
| Transcript | `…\transcripts\ictweb-decomm-20260924-1335.log` |
| IIS backup | `predecomm-20260924-1335` |
| Active sites | `Default Web Site` only |
| QuickLinks | App `Default Web Site/quicklinks`, pool `quicklinks`, `E:\webroot\quicklinks` |
| Redirect target | `https://uctools/quicklinks/` → 10.20.243.195 |
| Redirect scope | `applicationHost.config`, Location `Default Web Site/quicklinks` |
| Redirect config | Config A — fixed destination, 302 Found, `exactDestination=true` |
| Why Config A | uctools returns 404 on sub-paths |
| Pools stopped | ud, ucdashboard, etsdashboard, UserManagement, chatbot, iistest, IL3_Checks_Dev |
| Pools secured | Signagefeedadmin, SWPICTSignageFeedHub, SWPICTHub, SignageAdminApp |
| Pool left running | `quicklinks` — required for the redirect |
| Shared pool ⚠ | `DefaultAppPool` serves `/`, `/wac`, `/ADLockoutsSD/ADLockout` — Option A taken |
| Known issue | HTTPS `TrustFailure` — cert `953A0CC0…` bound at 0.0.0.0:443, not in the store. Pre-existing |
| Shutdown task | `\SWP-Decomm\Decommission - Scheduled Shutdown` — **not yet created** |
| Shutdown target | Wednesday 8 October 2026, 20:00 |
| Cancel shutdown | `Unregister-ScheduledTask -TaskName 'Decommission - Scheduled Shutdown' -TaskPath '\SWP-Decomm\' -Confirm:$false` |
