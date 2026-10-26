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

# INC 494025

# Three likely causes, in order of likelihood

# On-prem change hasn’t synced to the cloud. EXO’s copy of her mailbox still has Matthews2 as primary. This usually happens when Entra Connect hit a sync error on her object, such as a duplicate proxy address conflict.
# Send-from-alias is enabled in the tenant. When it’s on, replies to a message sent to an alias go out from that alias. So any external contact still emailing kirsty.matthews2@ gets replies from Matthews2. This fits “external only” well.
# Client side. She picked the old address in the From field, has a cached From entry, or is using a mobile app or old profile.

# Step-by-step checks (on your work device, EXO session)

Start-Transcript -Path "$env:USERPROFILE\Logs\KirstyYoung-OldAddress-$(Get-Date -f yyyyMMdd-HHmm).log"

Write-Host "=== [$(Get-Date -f s)] Step 1: Cloud view of mailbox ==="
Get-EXOMailbox -Identity 'Kirsty.Young@south-wales.police.uk' -Properties DisplayName,PrimarySmtpAddress,WindowsEmailAddress,UserPrincipalName,EmailAddresses,WhenChanged |
    Format-List DisplayName,PrimarySmtpAddress,WindowsEmailAddress,UserPrincipalName,WhenChanged,EmailAddresses

Write-Host "=== [$(Get-Date -f s)] Step 2: Send-from-alias setting ==="
Get-OrganizationConfig | Format-List SendFromAliasEnabled

Write-Host "=== [$(Get-Date -f s)] Step 3: What address her outbound mail actually used (5 days) ==="
foreach ($s in 'Kirsty.Young@south-wales.police.uk','Kirsty.Matthews2@south-wales.police.uk') {
    Get-MessageTraceV2 -SenderAddress $s -StartDate (Get-Date).AddDays(-5) -EndDate (Get-Date) |
        Where-Object { $_.RecipientAddress -notlike '*@south-wales.police.uk' } |
        Select-Object Received, SenderAddress, RecipientAddress, Status, Subject
}
Stop-Transcript

#How to read the results

# Step 1 shows PrimarySmtpAddress = Matthews2: it’s a sync problem (cause 1). Next we’d check Entra Connect sync errors for her object.
# Step 1 shows Young correctly and Step 2 is True: check whether the Matthews2 sends in Step 3 are replies to external people writing to her old address (cause 2).
# Both are clean but Step 3 still shows Matthews2 as sender: it’s client side (cause 3), so we’d look at how she’s sending.

# It would also help to know whether she’s using classic Outlook, new Outlook/OWA or a mobile device, and whether the affected emails are replies or new messages. Send me the output and we’ll go from there.

Start-Transcript -Path "$env:USERPROFILE\Logs\KirstyYoung-Step3-$(Get-Date -f yyyyMMdd-HHmm).log"
Write-Host "=== [$(Get-Date -f s)] Transport rules mentioning old name ==="
Get-TransportRule | Where-Object { ($_ | Out-String) -match 'Matthews' } | Select-Object Name, State, Priority

Write-Host "=== [$(Get-Date -f s)] OWA/roaming signature ==="
Get-MailboxMessageConfiguration -Identity 'Kirsty.Young@south-wales.police.uk' |
    Format-List SignatureText, SignatureHtml, AutoAddSignature, AutoAddSignatureOnReply
Stop-Transcript

Subject: Your call – old email address showing on external emails

Hi Kirsty,

I'm from the Unified Comms team and I've picked up your call about your old email address (Kirsty.Matthews2) showing when you email externally.

I've checked your mailbox and our mail logs, and everything you've sent externally over the last few days has gone out from Kirsty.Young@south-wales.police.uk. So the problem is likely somewhere other than the address itself. Could you help me with a few things so I can pin it down?

1. Where are you seeing the old address? For example, has someone outside SWP told you, are replies coming back addressed to Kirsty.Matthews2, or is it something you see yourself? If you have an example email, a screenshot or a forwarded copy would be really helpful.

2. Could you send me a quick test email? Just reply to this one with a line of text, exactly as you'd normally reply, with your usual signature included.

3. Which version of Outlook do you use? Is it the desktop app, Outlook on the web, or your work mobile? If you use more than one, does it happen on all of them?

Once I have those, I should be able to tell you what's causing it and get it sorted.

Thanks,
James
Unified Communications – Platforms
South Wales Police


##################################


Thanks for sending that over, Kirsty. I’ve checked everything on our side and your account is set up correctly: every email you send goes out from your new address, Kirsty.Young@south-wales.police.uk. I traced the exact email in your example and confirmed it left us with your new address. What’s happening is that Cardiff Council’s system still has an old saved contact for you under your previous name, so when people there reply or forward your emails, their system swaps in your old details. It’s a bit like a friend who still has your old number saved in their phone: your number is correct, but their phone still shows the old one. Nothing is wrong with your account, you don’t need to change anything, and any replies sent to your old address will still reach you. If it bothers you, the easiest fix is to ask your regular contacts at the Council to delete or update the saved contact for you, or to tell their IT team, and it should then show correctly.

#####################################

Subject: RE: Incident: 494025 - Old email address is showing

Hi Kirsty,

Thanks, that's really helpful and confirms what I suspected.

Your account is set up correctly. Every email you send goes out under your new name and address, which is why it looks right when you email your personal address.

The old details are coming from Tom's own Outlook at Cardiff Council. He most likely has an old contact saved for you under your previous name, and his Outlook uses it when he replies to or forwards your emails. It's a bit like someone who still has your old number saved in their phone: your number is fine, they just need to update their contacts.

If you could ask Tom to do the following, that should sort it:

1. Delete the old "Matthews, Kirsty" contact from his Outlook contacts.
2. Remove your old address from his suggestions. When he starts typing your name in a new email and the old address pops up, he can click the small X next to it.

In the meantime, any emails sent to your old address will still reach you, so nothing will be missed.

I'll close the ticket for now, but let me know if it carries on after Tom has updated his contacts.

Many thanks,
James

###########################################################################

Resolution: All SWP-side config verified correct (mailbox, sync, transport rules, signature); message trace and test headers confirm outbound mail sends as Kirsty.Young@south-wales.police.uk. Email to the user’s personal address displays correctly. Issue isolated to one external recipient (Cardiff Council), whose Outlook holds a stale contact/autocomplete entry under the user’s previous name. User advised to ask the recipient to remove the old contact. Old alias retained so mail to the previous address is still delivered. No SWP change required.
