# SWP Signage Feed Admin — v1.1.0 Deployment Runbook

**Server:** `swpapp-digisign.swp-rest.police.int`
**Application:** `/signageadmin` (Default Web Site)
**Database:** `E:\signagefeedadmin\data\feed.db`

> **Rolling back?** Go straight to the last section of this document,
> **Rollback — if something has gone wrong**. It is self-contained: it assumes
> a fresh PowerShell window and sets up everything it needs.

**What is in this release**

- Version number in every page footer, linking to a new `/signageadmin/changelog` page.
- Location targeting for the ICT Datacenter Team feed: each item is set to **HQ only**, **FW only**, or **All**.
- Each location publishes its own RSS file, so a restricted item never reaches the other site.

## Will the existing ticker items survive? Yes.

**Nothing the datacentre team has added is deleted, changed or hidden.** The
whole database change is one statement:

```sql
ALTER TABLE FeedItems ADD COLUMN Locations TEXT NOT NULL DEFAULT ''
```

That is additive only. No `DELETE`, no `UPDATE` of existing rows, no table
rebuild. Every existing item keeps its text, its publication date and its
active flag exactly as they are, and gains one new column set to `''`.

**`''` means every location.** So every item that exists today carries on
appearing on the HQ ticker, the FW ticker and in `datacenter.xml`. Opening one
in the editor shows **All** already selected, and saving it unchanged leaves it
exactly where it was.

The other three feeds — Service Desk, Systems and News — have no locations
configured at all, so they behave precisely as they do now.

This is not an assurance, it is tested. `Test-LocationTargeting.ps1` seeds a
row with `Locations = ''` labelled `TEST LEGACY EMPTY`, which stands for every
pre-upgrade item, and asserts it appears in all three files. That test passed
before you deployed.

Sections 2 and 5.2 count the items before and after so you can prove it on the
real data rather than take my word for it.

---

> **This release changes the database schema and the RSS output.** It adds a
> `Locations` column to `FeedItems` and publishes two new files. Read section 1
> before doing anything on the server.

---

## 0. Before you start

### 0.1 This code has not been compiled

It was written without a .NET SDK available, so **you are the first person to
build it**. Section 1 builds and runs it on your own machine first. Do not
deploy anything that has not got past section 1.

### 0.2 Transcript

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path 'E:\SignageAdmin\Deploy' | Out-Null
Start-Transcript -Path "E:\SignageAdmin\Deploy\deploy-v1.1.0-$stamp.log"
```

### 0.3 Things you will need

```powershell
$appcmd  = "$env:windir\system32\inetsrv\appcmd.exe"   # never on PATH
$pool    = '<YOUR APP POOL NAME>'                      # & $appcmd list apppool
$appPath = '<PHYSICAL PATH OF /signageadmin>'
$dbPath  = 'E:\signagefeedadmin\data\feed.db'
```

---

## 1. Build and test locally — before touching the server

### 1.1 Build

```powershell
cd C:\temp\SignageFeedAdmin_prod\SignageFeedAdmin
dotnet build
```

**Stop here if there are any errors.** Send me the full output and I will fix
them. Do not continue to section 2 with a failing build.

### 1.2 You cannot browse it locally — and do not need to

`dotnet run` will **not** give you a usable site. The app's default
authentication scheme is the IIS one (`IISServerDefaults.AuthenticationScheme`),
and that handler exists only when hosted in IIS. Outside it, the first request
throws "No authentication handler is registered for the scheme 'Windows'" and
every page returns 500. Nothing is wrong — it simply is not runnable as a
website outside IIS.

That matters less than it sounds, because the risky code does not need a
request. `FeedService.PublishAll()` runs at startup, **before** `app.Run()`, so
merely starting the app:

- binds and validates `appsettings.json` (`FeedCatalog` throws if it is wrong)
- creates the `Locations` column on an existing database
- writes all six RSS files, exercising the real HQ / FW / All separation

### 1.3 Verify the version and the changelog copy

```powershell
(Get-Item .\bin\Debug\net10.0\SignageFeedAdmin.dll).VersionInfo.ProductVersion
Test-Path .\bin\Debug\net10.0\App_Data\changelog.json
```

Expect `1.1.0` and `True`. The first is exactly what the page footer reads, so
this confirms the footer without needing to see it.

### 1.4 Test the separation locally

```powershell
Unblock-File .\Test-LocationTargeting.ps1
.\Test-LocationTargeting.ps1
```

`Unblock-File` clears the mark-of-the-web on a file that arrived from
elsewhere, which is the narrow fix for the signing prompt. If the execution
policy still blocks it, prefer a process-scoped bypass over a machine-wide
change:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-LocationTargeting.ps1
```

The test needs **only the .NET SDK** — no `sqlite3.exe` on this machine. The
database work runs through `tools\DbTool`, a small console project built on
demand that uses the same `Microsoft.Data.Sqlite` version as the application,
so the package is already in your NuGet cache.

It seeds four items into the project's own scratch database, starts and stops
the app twice, and asserts which feed each item reached:

| Seeded item | HQ feed | FW feed | `datacenter.xml` |
|---|---|---|---|
| `TEST HQ ONLY` | yes | **no** | **no** |
| `TEST FW ONLY` | **no** | yes | **no** |
| `TEST ALL EXPLICIT` | yes | yes | yes |
| `TEST LEGACY EMPTY` | yes | yes | yes |

It must print **PASS**. If it fails, do not deploy — send me the output.

It only ever touches `App_Data\feed.db` inside the project folder, and refuses
to run if `Feed:DbPath` has been changed from the default. `DbTool` only writes
rows whose id begins `test-`, so it cannot disturb real content even if pointed
at the wrong file. Production is not reachable from it.

> `tools\**` is excluded from the web project in the csproj. Without that the
> SDK's `**\*.cs` glob would compile `DbTool\Program.cs` into the application
> and the build would fail with CS8802, two sets of top-level statements. The
> exclusion also keeps the helper out of `dotnet publish`, so it never reaches
> the server.

### 1.5 What is left untested until deployment

Only the user interface: the three radios, the version in the footer, and the
changelog page. Those need Windows auth, so they are first seen on the server
at section 5.4 and section 6. Everything behind them has been verified above.

> If you want to see the UI before deploying, the options are an IIS Express
> launch profile (needs IIS Express installed) or deploying to the dev server
> first. I have deliberately **not** added a development-mode authentication
> bypass — on a police system that is a control that can be switched on by a
> stray environment variable, and it is not worth it to preview a form.

---

## 2. Back up

The schema migration runs automatically at startup and cannot be undone
in place. Take both backups.

```powershell
& $appcmd stop apppool /apppool.name:$pool
Start-Sleep -Seconds 3
& $appcmd list apppool $pool /text:state      # must say Stopped

Copy-Item $dbPath "E:\SignageAdmin\Deploy\feed-pre-v1.1.0-$stamp.db"
Copy-Item $appPath "E:\SignageAdmin\Deploy\publish-pre-v1.1.0-$stamp" -Recurse

Get-Item "E:\SignageAdmin\Deploy\feed-pre-v1.1.0-$stamp.db" | Select Name, Length
```

Confirm both exist and are non-zero before going on.

### 2.1 Record what is there now

```powershell
$before = C:\temp\sqlite3.exe $dbPath `
  "SELECT FeedId, COUNT(*) FROM FeedItems WHERE IsActive = 1 GROUP BY FeedId;"
$before
$before | Set-Content "E:\SignageAdmin\Deploy\item-counts-before-$stamp.txt"
```

Keep this. Section 5.2 compares against it, so you can show the datacentre team
their content survived rather than asserting it.

---

## 3. Publish and deploy

```powershell
cd C:\temp\SignageFeedAdmin_prod\SignageFeedAdmin
Remove-Item .\publish -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish -c Release -o .\publish
```

Confirm no generated feed XML is in the output — it must not overwrite the
live feeds:

```powershell
Get-ChildItem .\publish\wwwroot\feeds\rss\ -ErrorAction SilentlyContinue
```

Expect **nothing**. `wwwroot\feeds\rss\**` is excluded in the csproj, because
the SDK would otherwise glob any XML left in your local `wwwroot` — including
the items `Test-LocationTargeting.ps1` writes — into the publish output and
copy it over the live feeds. The app recreates and republishes the folder at
startup, so there is nothing to carry across.

Confirm the changelog made it into the output. The Web SDK globs `**\*.json`
into `Content`, so it should be there; the csproj pins the copy behaviour with
a `<Content Update=...>` entry rather than an `Include`, which would have
duplicated the glob and failed the build:

```powershell
Test-Path .\publish\App_Data\changelog.json      # must be True
Test-Path .\publish\App_Data\feed.db             # must be FALSE
```

The second check matters more than the first. Running the local test creates a
scratch `App_Data\feed.db` in the project. A `.db` file is not matched by the
SDK's default content globs, so it should not publish — but if it ever did,
deploying would copy an empty development database over
`E:\signagefeedadmin\data\feed.db` and destroy every live feed item. Confirm
`False` before copying anything to the server.

Then copy `publish\*` to `$appPath` as per your normal deployment.

> `web.config` is transformed on publish, not regenerated — the existing
> `forwardWindowsAuthToken` setting is preserved.

---

## 4. Place the external changelog

The app looks for `changelog.json` **beside the database first**, and falls
back to the copy inside the publish folder. Putting it beside the database
means a note can be corrected without a redeployment, because deploying
replaces the publish folder.

```powershell
Copy-Item "$appPath\App_Data\changelog.json" 'E:\signagefeedadmin\data\changelog.json'
```

This needs no configuration: the external path is derived from `Feed:DbPath`.
Set `Feed:ChangelogPath` only if you want it somewhere else.

---

## 5. Start and verify

```powershell
& $appcmd start apppool /apppool.name:$pool
Start-Sleep -Seconds 5
& $appcmd list apppool $pool /text:state      # must say Started
```

### 5.1 The application came up

```powershell
Invoke-WebRequest 'https://swpapp-digisign.swp-rest.police.int/signageadmin/' `
  -UseDefaultCredentials -UseBasicParsing | Select StatusCode
```

A 500 here usually means `FeedCatalog` rejected the config at startup. Check
the Windows Application event log — the message names the exact problem.

### 5.2 The schema migrated

```powershell
C:\temp\sqlite3.exe $dbPath "PRAGMA table_info(FeedItems);"
```

Expect a `Locations` row. Existing items keep `''`, which means **every
location** — so nothing disappeared from either ticker.

```powershell
C:\temp\sqlite3.exe $dbPath "SELECT COUNT(*) FROM FeedItems WHERE Locations = '';"
```

Now compare the item counts with what you recorded in section 2.1:

```powershell
$after = C:\temp\sqlite3.exe $dbPath `
  "SELECT FeedId, COUNT(*) FROM FeedItems WHERE IsActive = 1 GROUP BY FeedId;"

Compare-Object `
  (Get-Content "E:\SignageAdmin\Deploy\item-counts-before-$stamp.txt") `
  $after
```

**`Compare-Object` must return nothing.** Any output means a count changed,
which the migration cannot cause — stop and follow **Rollback** at the end of this document.

### 5.3 The new feeds exist

```powershell
Get-ChildItem "$appPath\wwwroot\feeds\rss\" | Select Name, Length, LastWriteTime
```

Expect six files: `servicedesk.xml`, `systems.xml`, `news.xml`,
`datacenter.xml`, and the two new `datacenter-hq.xml` and `datacenter-fw.xml`.
All six are written at startup, so they exist before anyone saves anything.

### 5.4 Version and changelog

Browse to `/signageadmin/` — the footer should read `v1.1.0` and link to the
changelog, which should mark 1.1.0 as "running now". If it warns that the
running version does not match the newest entry, the csproj `<Version>` and
`changelog.json` have fallen out of step.

---

## 6. Prove the separation works

**Do this before repointing any player.** It is the whole point of the release.

1. Open the Datacentre feed, add an item reading `HQ TEST ONLY`, select **HQ only**, save.
2. Then:

```powershell
$rss = "$appPath\wwwroot\feeds\rss"
"HQ   : " + (Select-String 'HQ TEST ONLY' "$rss\datacenter-hq.xml" -Quiet)
"FW   : " + (Select-String 'HQ TEST ONLY' "$rss\datacenter-fw.xml" -Quiet)
"both : " + (Select-String 'HQ TEST ONLY' "$rss\datacenter.xml"    -Quiet)
```

**Required result:**

| File | Expected |
|---|---|
| `datacenter-hq.xml` | `True` |
| `datacenter-fw.xml` | **`False`** |
| `datacenter.xml` | **`False`** |

Anything else means restricted content is reaching the wrong screens — stop,
follow **Rollback** at the end of this document, and tell me.

3. Edit the same item, select **All**, save, and re-run. All three now `True`.
4. Delete the test item.

---

## 7. Repoint the BrightSign players

Only after section 6 passes.

| Site | New feed URL |
|---|---|
| HQ | `http://swpapp-digisign.swp-rest.police.int/signageadmin/feeds/rss/datacenter-hq.xml` |
| FW | `http://swpapp-digisign.swp-rest.police.int/signageadmin/feeds/rss/datacenter-fw.xml` |

> HTTP, not HTTPS — the RSS carve-out for the players' feed subsystem is
> unchanged by this release.

There is **no deadline** on this. Until a player is repointed it keeps reading
`datacenter.xml`, which now carries only items shown at every site. It will
never show a restricted item. That was the point of keeping the file.

Once every datacentre player is repointed, decide whether to keep
`datacenter.xml` publishing. Leaving it costs nothing and is a safe fallback.

---

## 8. Stop the transcript

```powershell
Stop-Transcript
```

---

## 9. Adding a third site later

No rebuild. Add to the datacenter feed's `Locations` array in
`appsettings.json`, recycle the app pool, and the checkbox appears:

```json
{ "Id": "site3", "Name": "Site 3", "OutputPath": "wwwroot/feeds/rss/datacenter-site3.xml" }
```

Existing items are untouched. An item saved as HQ only stays HQ only and does
**not** appear at the new site. Items saved as **All** store an empty location
list, which means "every site" rather than "HQ and FW" — so they pick the new
site up automatically, and the combined `datacenter.xml` stays correct.

> **One consequence of the three-radio design.** The editor offers one site,
> or All. With a third site configured it would offer HQ only / FW only /
> Site 3 only / All — there is no way to express "HQ and FW but not Site 3".
> If you ever need that, tell me and I will switch that feed's editor to
> tickboxes; the stored data already supports any combination.

To remove location targeting entirely, delete the `Locations` array and
recycle — the feed reverts to one file for everyone.

---

# Rollback — if something has gone wrong

**Self-contained.** Assumes a brand new PowerShell window with none of the
variables from section 0 set. Follow it top to bottom.

## R1. Decide whether to roll back

| Situation | Action |
|---|---|
| App will not start, or `/signageadmin` returns 500 | Roll back |
| Section 6 leak test failed — a restricted item reached the wrong feed | **Roll back immediately**, then tell me |
| Item counts do not match section 2.1 | Roll back |
| Footer version missing, or changelog page errors | Do **not** roll back — cosmetic, fix forward |
| New RSS files absent but existing feeds fine | Do **not** roll back — check the event log first |

Rolling back is not free: it restores the database as it was at backup, so
**anything the datacentre team added since then is lost**. If people have been
adding items for hours, say so before you do it.

## R2. Set up

```powershell
$appcmd  = "$env:windir\system32\inetsrv\appcmd.exe"
$pool    = '<YOUR APP POOL NAME>'
$appPath = '<PHYSICAL PATH OF /signageadmin>'
$dbPath  = 'E:\signagefeedadmin\data\feed.db'
$deploy  = 'E:\SignageAdmin\Deploy'
```

Find the backups — the newest pair is the one from this deployment:

```powershell
Get-ChildItem $deploy -Filter 'feed-pre-v1.1.0-*.db'       | Sort LastWriteTime -Desc | Select -First 3 Name, Length, LastWriteTime
Get-ChildItem $deploy -Filter 'publish-pre-v1.1.0-*' -Dir  | Sort LastWriteTime -Desc | Select -First 3 Name, LastWriteTime
```

```powershell
$stamp     = '<THE STAMP FROM THE BACKUP NAMES, e.g. 20261018-214530>'
$dbBackup  = Join-Path $deploy "feed-pre-v1.1.0-$stamp.db"
$pubBackup = Join-Path $deploy "publish-pre-v1.1.0-$stamp"

if (-not (Test-Path $dbBackup))  { throw "No database backup at $dbBackup" }
if (-not (Test-Path $pubBackup)) { throw "No publish backup at $pubBackup" }
"Database backup : {0:N0} bytes, {1}" -f (Get-Item $dbBackup).Length, (Get-Item $dbBackup).LastWriteTime
"Publish backup  : {0} files"         -f (Get-ChildItem $pubBackup -Recurse -File).Count
```

**Stop here if either is missing.** Restoring binaries without the database, or
the reverse, leaves a worse state than the one you are in.

## R3. Have any players been repointed?

If you completed section 7, some BrightSign players now read
`datacenter-hq.xml` or `datacenter-fw.xml`. **Rolling back deletes those
files** — the old build does not publish them — so those screens will show an
empty ticker until you repoint them.

Point affected players back at the original feed **before** restoring:

```
http://swpapp-digisign.swp-rest.police.int/signageadmin/feeds/rss/datacenter.xml
```

If no player has been repointed yet, skip this and carry on.

## R4. Take a snapshot of the broken state first

You will want this to work out what happened, and it costs seconds.

```powershell
$fail = Join-Path $deploy "failed-v1.1.0-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $fail | Out-Null
Copy-Item $dbPath $fail -ErrorAction SilentlyContinue
Copy-Item "$appPath\wwwroot\feeds\rss\*.xml" $fail -ErrorAction SilentlyContinue
Get-EventLog -LogName Application -Newest 60 |
    Where-Object { $_.Source -match 'IIS|ASP.NET|\.NET' } |
    Format-List TimeGenerated, EntryType, Source, Message |
    Out-File (Join-Path $fail 'eventlog.txt')
"Snapshot: $fail"
```

## R5. Restore

```powershell
& $appcmd stop apppool /apppool.name:$pool
Start-Sleep -Seconds 3
& $appcmd list apppool $pool /text:state       # must say Stopped
```

Do not continue until it says `Stopped`. Copying over a running app gives file
locks and a half-restored folder.

```powershell
Remove-Item "$appPath\*" -Recurse -Force
Copy-Item "$pubBackup\*" $appPath -Recurse -Force
Copy-Item $dbBackup $dbPath -Force
```

**Both, always.** The old build tolerates the extra `Locations` column — its
`SELECT` lists are explicit, so it is ignored — but it does not write it. Leave
the new database in place and every item saved from then on silently loses its
targeting, while the HQ and FW feeds stop updating entirely.

```powershell
& $appcmd start apppool /apppool.name:$pool
Start-Sleep -Seconds 5
& $appcmd list apppool $pool /text:state       # must say Started
```

## R6. Verify the rollback

```powershell
Invoke-WebRequest 'https://swpapp-digisign.swp-rest.police.int/signageadmin/' `
  -UseDefaultCredentials -UseBasicParsing | Select StatusCode
```

Expect 200, and the footer should have **no** version number — that is how you
know the old build is running.

```powershell
C:\temp\sqlite3.exe $dbPath "SELECT FeedId, COUNT(*) FROM FeedItems WHERE IsActive = 1 GROUP BY FeedId;"
```

Compare with `item-counts-before-<stamp>.txt` from section 2.1. They must
match.

```powershell
Get-ChildItem "$appPath\wwwroot\feeds\rss\" | Select Name, Length, LastWriteTime
```

Expect the original four files, freshly written. `datacenter-hq.xml` and
`datacenter-fw.xml` will be gone — correct, the old build does not know them.

Then look at a real screen. A player is the only thing that proves the ticker
is working.

## R7. Afterwards

- Keep the `failed-v1.1.0-*` snapshot and the transcript. Send them to me.
- Tell the datacentre team which items were lost, if the backup was not recent.
- Do not retry the deployment until the cause is understood. The local test in
  section 1.4 passing means the targeting logic is sound, so a failure here is
  environmental — config, permissions, or the app pool.
