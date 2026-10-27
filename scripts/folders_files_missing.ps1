# EMAIL

Subject: Mailbox transfer – missing folders located

Hi,

Following the report of missing emails after the mailbox transfer, I've completed a full check of both mailboxes.

The good news is that nothing has been lost. Every folder from the previous mailbox arrived in the new one. The folders that appear to be missing, including the 3979 folders and nine calendars, are now in the new mailbox's Deleted Items with all their contents intact. They were moved there in a single action on Monday 26 October between 08:43 and 08:44, four days after the transfer had finished.

We can restore them straight away, either back to where they were originally or into a single folder (e.g. "Previous mailbox") so the new folder structure isn't affected. Please let me know which you'd prefer. In the meantime, please don't empty the Deleted Items folder.

If you would like us to establish who moved the folders and how, that would need a Microsoft Purview audit investigation. Purview is Microsoft 365's compliance and audit service; it records actions taken in mailboxes, such as which account moved or deleted items, when, and from which device or app. Access to it is restricted, so it would need to be requested and approved. Let me know if you'd like us to pursue this.

I've attached a summary of the findings and the evidence.

Kind regards,
James
Senior ICT Systems Engineer, Unified Communications

# Step 0 – Evidence folder and transcript

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out   = "C:\Temp\MailboxEvidence-$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Start-Transcript -Path "$out\transcript.txt"

$oldSmtp = 'old.address@south-wales.police.uk'
$newSmtp = 'new.address@south-wales.police.uk'

Write-Host "=== $(Get-Date -f s) | Step 0: identify mailboxes ==="
$old = Get-Mailbox -SoftDeletedMailbox -Identity $oldSmtp
$new = Get-Mailbox -Identity $newSmtp
$old, $new | Format-List DisplayName, ExchangeGuid, WhenSoftDeleted, ArchiveStatus, ArchiveGuid, RetentionPolicy, LitigationHoldEnabled

#Step 1 – Preserve the restore request report

# Do this step first. Completed requests are cleaned up automatically after a while, and this report is your strongest evidence.

Write-Host "=== $(Get-Date -f s) | Step 1: restore request ==="
Get-MailboxRestoreRequest | Format-Table Name, Status, TargetMailbox -AutoSize

$req   = Get-MailboxRestoreRequest -Name '<name from the list above>'
$stats = $req | Get-MailboxRestoreRequestStatistics -IncludeReport
$stats | Export-Clixml "$out\RestoreRequestStats.xml"

$stats | Format-List Status, StatusDetail, PercentComplete, QueuedTimestamp, CompletionTimestamp,
    EstimatedTransferItemCount, ItemsTransferred, BadItemsEncountered, LargeItemsEncountered,
    MissingItemsEncountered, DataConsistencyScore, FailureType, Message

$stats.Report.Entries  | Out-File "$out\RestoreReport-Entries.txt"
$stats.Report.BadItems, $stats.Report.LargeItems, $stats.Report.Failures | Out-File "$out\RestoreReport-Skipped.txt"

# Step 2 – Snapshot folders on both sides

Write-Host "=== $(Get-Date -f s) | Step 2: folder snapshots ==="
$props = 'FolderPath','FolderType','ItemsInFolder','FolderSize','CreationTime'

$oldFolders = Get-MailboxFolderStatistics -Identity $old.ExchangeGuid.ToString() -IncludeSoftDeletedRecipients | Select-Object $props
$newFolders = Get-MailboxFolderStatistics -Identity $new.ExchangeGuid.ToString() | Select-Object $props

$oldFolders | Export-Csv "$out\Old-Folders.csv" -NoTypeInformation
$newFolders | Export-Csv "$out\New-Folders.csv" -NoTypeInformation

# Also check the new mailbox's archive, if it has one
if ($new.ArchiveStatus -eq 'Active') {
    Get-MailboxFolderStatistics -Identity $new.ExchangeGuid.ToString() -Archive |
        Select-Object $props | Export-Csv "$out\New-ArchiveFolders.csv" -NoTypeInformation
}

# Step 3 – Compare

Write-Host "=== $(Get-Date -f s) | Step 3: compare ==="
$cmp = Compare-Object $oldFolders $newFolders -Property FolderPath -IncludeEqual -PassThru
$cmp | Group-Object SideIndicator | Select-Object Name, Count

$cmp | Where-Object SideIndicator -eq '<=' | Select-Object FolderPath, ItemsInFolder |
    Export-Csv "$out\Only-In-Old.csv" -NoTypeInformation
$cmp | Where-Object SideIndicator -eq '=>' | Select-Object FolderPath, ItemsInFolder, CreationTime |
    Export-Csv "$out\Only-In-New.csv" -NoTypeInformation

# Folders in both where the new side has FEWER items (new mail can only make it higher)
$newByPath = @{}; $newFolders | ForEach-Object { $newByPath[$_.FolderPath] = $_ }
$oldFolders | ForEach-Object {
    $n = $newByPath[$_.FolderPath]
    if ($n -and $n.ItemsInFolder -lt $_.ItemsInFolder) {
        [pscustomobject]@{ FolderPath = $_.FolderPath; OldItems = $_.ItemsInFolder; NewItems = $n.ItemsInFolder }
    }
} | Export-Csv "$out\Short-Folders.csv" -NoTypeInformation

Stop-Transcript

##############################################

# The restore request recorded the exact source GUID it copied from, so start there. Your transcript is still running, so carry on in the same window:

Write-Host "=== $(Get-Date -f s) | Step 0b: find old mailbox ==="
Get-MailboxRestoreRequest | Format-Table Name, Status, SourceMailbox, TargetMailbox -AutoSize

Get-Recipient -IncludeSoftDeletedRecipients -Filter "DisplayName -like '*Meyrick*'" |
    Format-Table Name, RecipientTypeDetails, PrimarySmtpAddress, ExchangeGuid, WhenSoftDeleted -AutoSize

Get-Mailbox -InactiveMailboxOnly -Filter "DisplayName -like '*Meyrick*'" |
    Format-Table DisplayName, PrimarySmtpAddress, ExchangeGuid -AutoSize

# If any of those shows the old mailbox’s ExchangeGuid, set $old from that GUID:

$old = Get-Mailbox -SoftDeletedMailbox -Identity '<old ExchangeGuid>'
# or, if it shows as active or inactive instead:
$old = Get-Mailbox -Identity '<old ExchangeGuid>'
$old | Format-List DisplayName, ExchangeGuid, WhenSoftDeleted, ArchiveStatus, ArchiveGuid, RetentionPolicy

# Step 0c – Load the old mailbox

$old = Get-Mailbox -Identity 'c8b56744-159b-434e-80b3-4267f527925d'
$old | Format-List DisplayName, PrimarySmtpAddress, RecipientTypeDetails, ExchangeGuid, WhenSoftDeleted, ArchiveStatus, RetentionPolicy

# Step 1 – Capture why the restore failed

Write-Host "=== $(Get-Date -f s) | Step 1: restore request ==="
$stats = Get-MailboxRestoreRequest -Name 'Trudi.Meyrick@south-wales.police.uk' |
    Get-MailboxRestoreRequestStatistics -IncludeReport
$stats | Export-Clixml "$out\RestoreRequestStats.xml"
$stats.Report.Entries | Out-File "$out\RestoreReport-Entries.txt"

$stats | Format-List Status, StatusDetail, FailureType, FailureSide, FailureTimestamp, Message,
    Source*, Target*, QueuedTimestamp, LastUpdateTimestamp, PercentComplete,
    EstimatedTransferItemCount, ItemsTransferred, BadItemsEncountered, LargeItemsEncountered

$stats.Report.Failures | Select-Object -Last 3 | Format-List Timestamp, FailureType, Message

# Step 2 – Snapshot folders (old mailbox is active, so no soft-deleted switch)

Write-Host "=== $(Get-Date -f s) | Step 2: folder snapshots ==="
$props = 'FolderPath','FolderType','ItemsInFolder','FolderSize','CreationTime','NewestItemReceivedDate'

$oldFolders = Get-MailboxFolderStatistics -Identity $old.ExchangeGuid.ToString() -IncludeOldestAndNewestItems | Select-Object $props
$newFolders = Get-MailboxFolderStatistics -Identity '05a9f09e-14ff-48a6-abfc-f749ca483433' -IncludeOldestAndNewestItems | Select-Object $props

$oldFolders | Export-Csv "$out\Old-Folders.csv" -NoTypeInformation
$newFolders | Export-Csv "$out\New-Folders.csv" -NoTypeInformation

# Save the skipped/large item detail too
$stats.Report.LargeItems   | Format-List * | Out-File "$out\RestoreReport-LargeItems.txt"
$stats.Report.MissingItems | Format-List * | Out-File "$out\RestoreReport-MissingItems.txt"

# Step 3 – Compare against the copy start time

Write-Host "=== $(Get-Date -f s) | Step 3: compare ==="
$copyStart = $stats.QueuedTimestamp
$cmp = Compare-Object $oldFolders $newFolders -Property FolderPath -PassThru

"--- Only in OLD ---"
$cmp | Where-Object SideIndicator -eq '<=' |
    Select-Object FolderPath, ItemsInFolder, CreationTime, NewestItemReceivedDate,
        @{n='CreatedAfterCopy'; e={ $_.CreationTime -gt $copyStart }} |
    Tee-Object -Variable onlyOld | Format-Table -AutoSize
$onlyOld | Export-Csv "$out\Only-In-Old.csv" -NoTypeInformation

"--- Only in NEW ---"
$cmp | Where-Object SideIndicator -eq '=>' |
    Select-Object FolderPath, ItemsInFolder, CreationTime |
    Tee-Object -Variable onlyNew | Format-Table -AutoSize
$onlyNew | Export-Csv "$out\Only-In-New.csv" -NoTypeInformation

# Step 4a – Prove the 2021-dated folders came from the copy

Write-Host "=== $(Get-Date -f s) | Step 4: confirm ==="
Get-Mailbox -Identity '05a9f09e-14ff-48a6-abfc-f749ca483433' | Format-List DisplayName, WhenMailboxCreated

# Step 4b – What the restore log says about the calendar folders

Select-String -Path "$out\RestoreReport-Entries.txt" -Pattern 'Davis|Hughes|Williams|Calendar|corrupt|skip' |
    Select-Object -First 30 | ForEach-Object Line

# Step 4c – Deleted-item counts on both sides

"--- OLD ---"
Get-MailboxFolderStatistics -Identity $old.ExchangeGuid.ToString() -FolderScope RecoverableItems |
    Format-Table FolderPath, ItemsInFolder, FolderSize -AutoSize
"--- NEW ---"
Get-MailboxFolderStatistics -Identity '05a9f09e-14ff-48a6-abfc-f749ca483433' -FolderScope RecoverableItems |
    Format-Table FolderPath, ItemsInFolder, FolderSize -AutoSize

# Step 5a – Skipped items by folder

Write-Host "=== $(Get-Date -f s) | Step 5a: skipped items by folder ==="
$skipped = @($stats.Report.BadItems) + @($stats.Report.LargeItems) + @($stats.Report.MissingItems) | Where-Object { $_ }
"Total skipped records: $($skipped.Count)"
$skipped | Group-Object Kind, FolderName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
$skipped | Select-Object Kind, FolderName, Subject, DateSent, MessageSize |
    Export-Csv "$out\Skipped-Items.csv" -NoTypeInformation

# Step 5b – Cleaner restore log filter

Write-Host "=== $(Get-Date -f s) | Step 5b: restore log ==="
$stats.Report.Entries |
    Where-Object { $_.LocalizedString -notmatch 'TotalTimeProcessingMessages' -and
                   $_.LocalizedString -match 'Calendar|corrupt|fail|consisten|missing|Davis|Hughes|Williams' } |
    Select-Object -Last 40 | ForEach-Object LocalizedString

# Step 5c – Audit log: deletes and moves in both mailboxes

Write-Host "=== $(Get-Date -f s) | Step 5c: audit log ==="
$ops   = 'SoftDelete','HardDelete','MoveToDeletedItems','Move'
$audit = foreach ($mbx in 'Trudi.Meyrick@south-wales.police.uk','Trudi.Meyrick1@south-wales.police.uk') {
    Search-UnifiedAuditLog -StartDate '2026-10-20' -EndDate (Get-Date) -Operations $ops -FreeText $mbx -ResultSize 5000
}
$audit = $audit | Sort-Object Identity -Unique

$rows = $audit | ForEach-Object {
    $d = $_.AuditData | ConvertFrom-Json
    [pscustomobject]@{
        Time       = $_.CreationDate
        Mailbox    = $d.MailboxOwnerUPN
        Operation  = $_.Operations
        By         = $_.UserIds
        Folder     = $d.Folder.Path
        DestFolder = $d.DestFolder.Path
        Items      = @($d.AffectedItems).Count
        Client     = $d.ClientInfoString
    }
} | Sort-Object Time
$rows | Export-Csv "$out\Audit-Deletes-Moves.csv" -NoTypeInformation

$rows | Group-Object Mailbox, Operation, By | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
$rows | Where-Object { "$($_.Folder) $($_.DestFolder)" -match 'Calendar|Chief Supt' } |
    Format-Table Time, Mailbox, Operation, By, Folder, DestFolder, Items -AutoSize

# Step 6a – Live check of the disputed folders

Write-Host "=== $(Get-Date -f s) | Step 6a: live check ==="
$liveOld = Get-MailboxFolderStatistics -Identity $old.ExchangeGuid.ToString()
$liveNew = Get-MailboxFolderStatistics -Identity '05a9f09e-14ff-48a6-abfc-f749ca483433'

"--- OLD (live) ---"
$liveOld | Where-Object FolderPath -match '^/Inbox/3979|BCU' | Format-Table FolderPath, ItemsInFolder -AutoSize
"--- NEW (live) ---"
$liveNew | Where-Object FolderPath -match '^/Inbox/3979|BCU' | Format-Table FolderPath, ItemsInFolder -AutoSize

"Folder count now   - Old: $($liveOld.Count)  New: $($liveNew.Count)"
"Folder count 15:16 - Old: $($oldFolders.Count)  New: $($newFolders.Count)"

# Step 6b – Who has access, and when each mailbox was last used

Write-Host "=== $(Get-Date -f s) | Step 6b: access and activity ==="
foreach ($id in $old.ExchangeGuid.ToString(), '05a9f09e-14ff-48a6-abfc-f749ca483433') {
    "===== $id ====="
    Get-MailboxPermission -Identity $id |
        Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and -not $_.Deny -and -not $_.IsInherited } |
        Format-Table User, AccessRights -AutoSize
    Get-MailboxStatistics -Identity $id | Format-List LastUserActionTime, LastInteractionTime, LastLogonTime
}

"--- Calendar delegates OLD ---"
Get-MailboxFolderPermission -Identity 'Trudi.Meyrick@south-wales.police.uk:\Calendar' | Format-Table User, AccessRights, SharingPermissionFlags -AutoSize
"--- Calendar delegates NEW ---"
Get-MailboxFolderPermission -Identity 'Trudi.Meyrick1@south-wales.police.uk:\Calendar' | Format-Table User, AccessRights, SharingPermissionFlags -AutoSize

# Step 7a – Full snapshots, no cap

Write-Host "=== $(Get-Date -f s) | Step 7a: full snapshots ==="
$props  = 'FolderPath','FolderType','ItemsInFolder','FolderSize','CreationTime'
$oldAll = Get-MailboxFolderStatistics -Identity $old.ExchangeGuid.ToString() -ResultSize Unlimited | Select-Object $props
$newAll = Get-MailboxFolderStatistics -Identity '05a9f09e-14ff-48a6-abfc-f749ca483433' -ResultSize Unlimited | Select-Object $props
"Folder count - Old: $($oldAll.Count)  New: $($newAll.Count)"
$oldAll | Export-Csv "$out\Old-Folders-Full.csv" -NoTypeInformation
$newAll | Export-Csv "$out\New-Folders-Full.csv" -NoTypeInformation

# Step 7b – Top-level Inbox folders (what you saw in Outlook)

Write-Host "=== $(Get-Date -f s) | Step 7b: Inbox top level ==="
"--- OLD ---"
$oldAll | Where-Object FolderPath -match '^/Inbox/[^/]+$' | Format-Table FolderPath, ItemsInFolder, CreationTime -AutoSize
"--- NEW ---"
$newAll | Where-Object FolderPath -match '^/Inbox/[^/]+$' | Format-Table FolderPath, ItemsInFolder, CreationTime -AutoSize

# Step 7c – Full compare: folders, then item counts

Write-Host "=== $(Get-Date -f s) | Step 7c: full compare ==="
$cmp     = Compare-Object $oldAll $newAll -Property FolderPath -PassThru
$onlyOld = $cmp | Where-Object SideIndicator -eq '<=' | Select-Object FolderPath, ItemsInFolder, CreationTime
$onlyNew = $cmp | Where-Object SideIndicator -eq '=>' | Select-Object FolderPath, ItemsInFolder, CreationTime
"Only in OLD: $(@($onlyOld).Count)   Only in NEW: $(@($onlyNew).Count)"
$onlyOld | Export-Csv "$out\Only-In-Old-Full.csv" -NoTypeInformation
$onlyNew | Export-Csv "$out\Only-In-New-Full.csv" -NoTypeInformation
"--- Only in OLD ---"; $onlyOld | Format-Table -AutoSize
"--- Only in NEW ---"; $onlyNew | Format-Table -AutoSize

$newByPath = @{}; $newAll | ForEach-Object { $newByPath[$_.FolderPath] = $_ }
$diff = $oldAll | ForEach-Object {
    $n = $newByPath[$_.FolderPath]
    if ($n) { [pscustomobject]@{ FolderPath = $_.FolderPath; Old = $_.ItemsInFolder; New = $n.ItemsInFolder; Diff = $n.ItemsInFolder - $_.ItemsInFolder } }
}
$diff | Export-Csv "$out\Matched-Folder-Counts.csv" -NoTypeInformation
"--- Fewer items in NEW (top 20) ---"
$diff | Where-Object Diff -lt 0 | Sort-Object Diff | Select-Object -First 20 | Format-Table -AutoSize
"--- More items in NEW (top 10) ---"
$diff | Where-Object Diff -gt 0 | Sort-Object Diff -Descending | Select-Object -First 10 | Format-Table -AutoSize

# Step 8a – When, and who has rights to those folders

Write-Host "=== $(Get-Date -f s) | Step 8a: when moved / folder rights ==="
$newGuid = '05a9f09e-14ff-48a6-abfc-f749ca483433'

"--- Top-level folders in Deleted Items (NEW) ---"
Get-MailboxFolderStatistics -Identity $newGuid -FolderScope DeletedItems |
    Where-Object FolderPath -match '^/Deleted Items/[^/]+$' |
    Format-Table FolderPath, ItemsInFolder, CreationTime, LastMovedTimeStamp, LastModifiedTime -AutoSize

"--- Calendar subfolders (NEW) ---"
Get-MailboxFolderStatistics -Identity $newGuid -FolderScope Calendar |
    Format-Table FolderPath, ItemsInFolder, CreationTime -AutoSize

foreach ($f in 'Inbox','Deleted Items') {
    "--- Folder permissions NEW :\$f ---"
    Get-MailboxFolderPermission -Identity "Trudi.Meyrick1@south-wales.police.uk:\$f" |
        Format-Table User, AccessRights, SharingPermissionFlags -AutoSize
}

# Step 8b – How long Deleted Items is kept

Write-Host "=== $(Get-Date -f s) | Step 8b: Deleted Items retention ==="
Get-RetentionPolicyTag | Where-Object Type -eq 'DeletedItems' |
    Format-Table Name, AgeLimitForRetention, RetentionAction, RetentionEnabled -AutoSize
(Get-RetentionPolicy 'Default MRM Policy').RetentionPolicyTagLinks

# Step 9 – Last PowerShell step: move timestamps and safety net, then close the transcript

Write-Host "=== $(Get-Date -f s) | Step 9: move timestamps and safety net ==="
Get-MailboxFolderStatistics -Identity $newGuid -ResultSize Unlimited |
    Where-Object FolderPath -match '^/Deleted Items/[^/]+$' |
    Format-Table FolderPath, ItemsInFolder, LastMovedTimeStamp, LastModifiedTime -AutoSize

Get-Mailbox -Identity $newGuid | Format-List RetainDeletedItemsFor
Stop-Transcript
