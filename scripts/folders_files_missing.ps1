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

