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
