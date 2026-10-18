# SWP Signage Feed Admin — v1.1.0 Deployment Runbook

**Server:** `swpapp-digisign.swp-rest.police.int`
**Application:** `/signageadmin` (Default Web Site)
**Database:** `E:\signagefeedadmin\data\feed.db`

**What is in this release**

- Version number in every page footer, linking to a new `/signageadmin/changelog` page.
- Location targeting for the ICT Datacenter Team feed: each item is set to **HQ only**, **FW only**, or **All**.
- Each location publishes its own RSS file, so a restricted item never reaches the other site.

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

### 1.2 Run it locally

```powershell
dotnet run
```

Then browse the local URL it prints and confirm:

| Check | Expected |
|---|---|
| Any page footer | shows `v1.1.0`, which links to the changelog |
| `/changelog` | lists 1.1.0 and 1.0.0, with 1.1.0 marked "running now" |
| Datacentre feed, Add item | a **Where should this appear?** box with three radios: HQ only, FW only, All — **All** preselected |
| Other three feeds, Add item | **no** location box — they are unchanged |
| Open an item created before this release | **All** preselected, and saving it unchanged leaves it on both tickers |

If the application fails to start with a configuration error, that is
`FeedCatalog` rejecting `appsettings.json` on purpose — the message names the
problem. Fix the config rather than bypassing the check.

Stop it with Ctrl+C when done.

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

---

## 3. Publish and deploy

```powershell
cd C:\temp\SignageFeedAdmin_prod\SignageFeedAdmin
Remove-Item .\publish -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish -c Release -o .\publish
```

Confirm the changelog made it into the output. The Web SDK globs `**\*.json`
into `Content`, so it should be there; the csproj pins the copy behaviour with
a `<Content Update=...>` entry rather than an `Include`, which would have
duplicated the glob and failed the build:

```powershell
Test-Path .\publish\App_Data\changelog.json      # must be True
```

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
roll back per section 8, and tell me.

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

## 8. Rollback

```powershell
& $appcmd stop apppool /apppool.name:$pool
Start-Sleep -Seconds 3

Remove-Item "$appPath\*" -Recurse -Force
Copy-Item "E:\SignageAdmin\Deploy\publish-pre-v1.1.0-$stamp\*" $appPath -Recurse
Copy-Item "E:\SignageAdmin\Deploy\feed-pre-v1.1.0-$stamp.db" $dbPath -Force

& $appcmd start apppool /apppool.name:$pool
```

**Restore the database too, not just the binaries.** The old build does not
know about the `Locations` column. It would not crash — its `SELECT` lists are
explicit, so the extra column is ignored — but any item saved by the old build
loses its targeting, and the two new RSS files would stop updating while
players still read them.

---

## 9. Stop the transcript

```powershell
Stop-Transcript
```

---

## 10. Adding a third site later

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
