# SWP Signage Feed Admin — Audit Log Maintenance Runbook

**Server:** `swpapp-digisign.swp-rest.police.int`
**Application:** `/signageadmin` (Default Web Site)
**Database:** `E:\signagefeedadmin\data\feed.db` (SQLite)

> The deployed `Feed:DbPath` points outside the application folder, so it is
> **not** the repository default of `App_Data\feed.db`. The script reads
> `Feed:DbPath` from the deployed `appsettings*.json` rather than assuming,
> and `-DbPath` overrides everything.

> **No redeployment.** Everything here operates on the SQLite database file.
> The application binaries, `web.config` and IIS configuration are untouched.
> No `dotnet build`, no `dotnet publish`, no file copy into the app folder.

---

## 1. Why this is done at the database, not in the app

The alternative was an admin "clear log" page inside the application. That was
rejected for two reasons:

1. It requires a full rebuild and redeploy — explicitly out of scope.
2. It ships a permanent control that erases the application's own
   accountability record, to a team that did not build the system. A
   database-level task performed once, with an archive retained, leaves a
   far better account of itself than a button anyone can press.

---

## 2. Prerequisite — `sqlite3.exe`

The app references `Microsoft.Data.Sqlite` 10.0.11, which targets .NET 10 and
**cannot be loaded by Windows PowerShell 5.1**. The app's own DLLs are therefore
not usable from a script. Use the standalone SQLite CLI instead.

1. From <https://sqlite.org/download.html> download **`sqlite-tools-win-x64`**.
2. Extract `sqlite3.exe` — a single ~1.5 MB binary. Nothing is installed and
   nothing is written to the registry.
3. Place it beside the script, or pass `-SqliteExe <path>`.

Route it to the server through your usual GitHub path if direct download is
blocked.

**Verify before use:**

```powershell
.\sqlite3.exe -version
```

---

## 3. Option A — one-off purge before handover *(recommended)*

Clears your POC and test entries so the datacentre team's trail starts clean
at go-live.

### 3.0 Confirm the app pool name

```powershell
appcmd list apppool
```

Pass the right one with `-AppPoolName`. If it does not match, the script stops
**before deleting anything** and lists the pools that do exist.

### 3.1 Dry run first — changes nothing

```powershell
cd E:\SignageAdmin\AuditMaintenance

.\Clear-SignageAuditLog.ps1 -DbPath 'E:\signagefeedadmin\data\feed.db' -Before '2026-10-13'
```

`-DbPath` is the reliable option here, since the database sits outside the
application folder. Omit it only if you want the script to read `Feed:DbPath`
from the deployed config itself.

Reports the total, what is in scope, what will remain, and a per-feed
breakdown with date ranges. **It still takes the backup and writes the CSV
archive**, so you can inspect exactly what would go before committing.

Check the breakdown against what you expect. If the "will remain" count is not
what you intended, adjust `-Before` and run again.

### 3.2 Execute

```powershell
.\Clear-SignageAuditLog.ps1 -DbPath 'E:\signagefeedadmin\data\feed.db' -Before '2026-10-13' -Execute
```

Sequence: backup → CSV archive → verify archive matches scope → stop app pool →
delete → write purge record → `VACUUM` → verify counts → `PRAGMA integrity_check`
→ start app pool → smoke test `/signageadmin/Audit`.

### 3.3 Scope options

All of these take `-DbPath 'E:\signagefeedadmin\data\feed.db'` as well.

| Need | Command |
|---|---|
| Everything before handover | `-Before '2026-10-13' -Execute` |
| One feed only | `-Before '2026-10-13' -FeedId datacenter -Execute` |
| Absolutely everything | `-All -Execute` |
| Rolling 12-month trim | `-Before (Get-Date).AddMonths(-12) -Execute` |

A **bare date is treated as UTC midnight**, not local. Under BST a bare date
parsed as local time lands at 23:00 UTC the previous day and would quietly
sweep up an extra hour of entries. Pass a date *with* a time if you want local
conversion — that is honoured as deliberate.

---

## 4. Option B — ongoing retention (scheduled task)

Keeps the log bounded without anyone having to remember. Same script.

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "E:\SignageAdmin\AuditMaintenance\Clear-SignageAuditLog.ps1" -DbPath "E:\signagefeedadmin\data\feed.db" -Before ([datetime]::UtcNow.AddMonths(-12)) -Execute'

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 02:00

Register-ScheduledTask -TaskName 'SWP Signage - Audit Retention' `
    -Action $action -Trigger $trigger `
    -User 'SWP-NET\svc_signage' -RunLevel Highest `
    -Description 'Trims the signage audit log to 12 months. Archives to CSV before deleting.'
```

Confirm the retention period with the datacentre team and whoever owns
information management before enabling it. Every run leaves its own transcript
and CSV archive in the working folder.

---

## 5. What the script guarantees

| Guarantee | How |
|---|---|
| Nothing is lost silently | Timestamped DB backup **and** CSV of every removed row, before any delete |
| The archive is complete | Exported row count is compared to the in-scope count; mismatch aborts |
| Clearing is never invisible | A `Purge` entry is written recording who, when, how many, the filter and the archive filename |
| Purge records cannot be erased | `Action <> 'Purge'` is forced into **every** filter, including `-All` |
| Safe by default | Without `-Execute` it reports only |
| Deleted data is not recoverable from free pages | `VACUUM` after delete |
| Database is sound afterwards | `PRAGMA integrity_check` |
| Full record of the operation | `Start-Transcript` for the whole run |
| Right database | Aborts unless an `AuditLog` table is present |
| App is genuinely stopped | Pool name validated, then stop confirmed via `/text:state` before any delete |

---

## 6. Rollback

The app pool is stopped during the delete, so there is no partial-write risk.
To restore:

```powershell
appcmd stop apppool /apppool.name:SignageFeedAdminPool

Copy-Item 'E:\SignageAdmin\AuditMaintenance\feed-<stamp>.db' `
          'E:\signagefeedadmin\data\feed.db' -Force

appcmd start apppool /apppool.name:SignageFeedAdminPool
```

Then browse `/signageadmin/Audit` and confirm the history is back.

---

## 7. Manual alternative

If you would rather not run the script:

```powershell
appcmd stop apppool /apppool.name:SignageFeedAdminPool

Copy-Item 'E:\signagefeedadmin\data\feed.db' "E:\SignageAdmin\feed-backup-$(Get-Date -f yyyyMMdd-HHmmss).db"

.\sqlite3.exe -header -csv 'E:\signagefeedadmin\data\feed.db' `
  "SELECT * FROM AuditLog WHERE TimestampUtc < '2026-10-13T00:00:00Z' AND Action <> 'Purge';" > archive.csv

.\sqlite3.exe 'E:\signagefeedadmin\data\feed.db' @"
BEGIN;
DELETE FROM AuditLog WHERE TimestampUtc < '2026-10-13T00:00:00Z' AND Action <> 'Purge';
INSERT INTO AuditLog (FeedId, TimestampUtc, UserName, Action, ItemId, Summary)
VALUES ('', '$([datetime]::UtcNow.ToString('o'))', '$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)',
        'Purge', NULL, 'Audit log cleared prior to datacentre handover. Archive: archive.csv');
COMMIT;
VACUUM;
"@

appcmd start apppool /apppool.name:SignageFeedAdminPool
```

Keep the backup and `archive.csv` together. They are the record of what was
removed.

---

## 8. Handover note

Give the datacentre team:

- the backup `.db` and the CSV archive, or their agreed storage location
- the retention period, if Option B was enabled
- the fact that `Purge` entries exist and cannot be deleted from the application

The application itself has **no** log-clearing function. Clearing requires
server access, the SQLite CLI, and leaves a transcript — which is the correct
bar for this operation.
