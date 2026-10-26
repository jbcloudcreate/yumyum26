# Incident 493413

# tep 1: Scope it. Is this only Eleri, or every SWP sender to this domain?

Start-Transcript -Path "$env:USERPROFILE\Logs\Athena-NDR-$(Get-Date -f yyyyMMdd-HHmm).log"
Write-Host "=== [$(Get-Date -f s)] Message trace: all senders to Athena (10 days) ==="
foreach ($r in 'm.jackson@athenaforensics.co.uk','enquiries@athenaforensics.co.uk') {
    Get-MessageTraceV2 -RecipientAddress $r -StartDate (Get-Date).AddDays(-10) -EndDate (Get-Date) |
        Select-Object Received, SenderAddress, RecipientAddress, Status, Subject
}

# If other SWP users get through fine, the problem is specific to Eleri’s address. If everyone fails, it’s our inbound path or their host.

# Step 2: Confirm her address resolves as a recipient.

Write-Host "=== [$(Get-Date -f s)] Recipient check ==="
Get-EXORecipient -Identity 'Eleri.Phillips@south-wales.police.uk' |
    Select-Object DisplayName, RecipientTypeDetails, PrimarySmtpAddress, EmailAddresses, WhenChanged
Stop-Transcript

# Step 3: Check where SWP’s inbound MX actually lands.

Resolve-DnsName south-wales.police.uk -Type MX

# Step 4: Reproduce the callout yourself. Run this from an external box such as a VPS or homelab, since port 25 out of the SWP estate will likely be blocked:

telnet <SWP MX host> 25
EHLO test.example
MAIL FROM:<>
RCPT TO:<Eleri.Phillips@south-wales.police.uk>
QUIT
