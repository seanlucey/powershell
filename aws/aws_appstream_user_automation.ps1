#Resolves AppStream Access & Login tickets. Retrieves info by pulling Access & Login tickets from a Jira Helpdesk ticket. 

# Create local log file.
if (!(Test-Path "$env:USERPROFILE\Documents\User Creation Logs")){
 mkdir "$env:USERPROFILE\Documents\User Creation Logs" >$null 2>&1
}

$month = Get-Date -Format "MM"
$day = Get-Date -Format "dd"
new-item -ItemType "directory" -path "$env:USERPROFILE\Documents\User Creation Logs\$month\$day" -force >$null 2>&1

$FileTimeStamp = Get-Date -UFormat "%d%m%Y_%H%M%S"
$LogFile = New-Item -ItemType File -Path "$env:USERPROFILE\Documents\User Creation Logs\$month\$day" -Name $env:computername"_Logs_$FileTimeStamp.log"
Start-Transcript -path "$env:USERPROFILE\Documents\User Creation Logs\$month\$day\$($env:computername)_Logs_$FileTimeStamp.log" -append >$null 2>&1

Import-Module JiraPS
Set-JiraConfigServer 'https://company.atlassian.net'
$user = "user"
$pass = convertto-securestring -String "123456789" -AsPlainText -Force 
$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $pass
Get-JiraIssue -Query 'project = "helpdesk" AND created >= -1d' -Credential $Credential | Select Key, Components, Status | Export-CSV "ticket.csv" -notypeinformation
Start-Sleep -s 2

# Extract tickets with components
Import-Csv -Path 'ticket.csv' | ForEach-Object {

    $component = $_.components -replace '@{self=https://company.atlassian.net/rest/api/2/component/\d{5}; id=\d{5}; name=',''
    $components = $component -replace '}',''

    $_.components = $components
    $_

} | Export-Csv -Path 'ticket2.csv' -NoTypeInformation

# Only keep Access & Login tickets that are open
Import-Csv -Path 'ticket2.csv' | Where-Object {
    $_.components -match "Access & Login" -And $_.status -match "Waiting for Support"
} | Export-Csv -Path 'ticket3.csv' -NoTypeInformation

# Check if no tickets detected, exit script if so
If ((Get-Content "ticket3.csv") -eq $Null) {
        Write-Host "**********************"
        Write-Host "No new AppStream tickets detected"
        Stop-Transcript >$null 2>&1
        Continue
        }

Import-Csv -Path 'ticket3.csv' | ForEach-Object {
       
    Write-Host "**********************"
    $ticket = $($_.Key)

    Write-Host "Resolving ticket: $ticket"
    $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $pass
    Get-JiraIssue -Key $ticket -Credential $Credential | Select Summary, Description, customfield_10900,customfield_12201 | Export-CSV "data.csv" -notypeinformation
    Start-Sleep -s 2

    #arrays for returning information to client tickets
    $array_resend_welcome = @()
    $array_already_exists = @()
    $array_created = @()
    $array_assign = @()

        Import-Csv -Path 'data.csv' | ForEach-Object {
            #extract email addresses
            $regex = "(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|`"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*`")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9]))\.){3}(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9])|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])"
            $regex_first_name = "(?:[a-z0-9!#$%&'*+/=?^_`{|}~-])"
            $find_email = $_.description
            $results = ($find_email | Select-String $regex -AllMatches).Matches
    
    #Renames client name
    $customer_new = $_.customfield_10900 -replace '@{self=https://company.atlassian.net/rest/api/2/customFieldOption/\d{5}; value=',''
    $customer1 = $customer_new -replace '; id=\d{5}}',''
    $customer2 = $customer1.Substring(0, $customer1.IndexOf('-'))
    $customer2 = $customer2.Substring(0,$customer2.Length-1)
    
    $_.customfield_10900 = $customer2
    $_

    #rename environment
    $customer_envir = $_.customfield_12201 -replace '@{self=https://genesisvmi.atlassian.net/rest/api/2/customFieldOption/\d{5}; value=',''
    $environment = $customer_envir -replace '; id=\d{5}}',''
        
    $_.customfield_12201 = $environment
    $_
} | Export-Csv -Path 'C:\Users\Administrator\Downloads/data2.csv' -NoTypeInformation

#Exit script if no email detected. Possibly not an access ticket
if ($results -eq $Null){
    Write-Host "$ticket : No email detected. Skipping ticket."
    continue }

#Exit script if no stack detected.
$Stack_exists = aws appstream describe-stacks --name $Stack
IF([string]::IsNullOrEmpty($Stack_exists)) {
   Write-Host "$ticket : No client environment detected"
   $ticket_response_exit = "Hello, Unfortunately we were unable to fulfill this request as we are unable detect the client environment. When creating a request of this type, please specify the environments prefix at the start of the Title or in the Customer field. This is how we are able to determine who this request is for. Can you please edit the Title or Customer field to meet this requirement, or close out this ticket and create a new one. Thank you."
   Add-JiraIssueComment -Comment $ticket_response_exit -Issue $ticket -Credential $Credential >$null 2>&1
   Invoke-JiraIssueTransition -Issue $ticket -Transition 851 -Credential $Credential
   continue }

$Stack = $customer2 + "_" + $client
Write-Host "Assigning to $Stack"

# For iteration
$createi = 0
$assigni = 0
$resendi = 0
$existsi = 0

foreach ($item in ($results)) {
    
    #Detect first name and last name from a . in between
    $firstName = ("$item".Split(".")[0]).replace(".","").ToLower()
    $lastName = ("$item".Split(".@")[1]).replace(".","").ToLower()
    #Remove numbering in name
    $firstNameNum = $firstName -replace '[^a-zA-Z-]',''
    $lastNameNum = $lastName -replace '[^a-zA-Z-]',''
    $EmailProper = $Email -replace '[<>:\\]',''.Trim()
    $Emails = $EmailProper -replace '''', ""
    #Capitalize first character in name
    $firstNameProper = (Get-Culture).TextInfo.ToTitleCase($firstNameNum.ToLower())
    $lastNameProper = (Get-Culture).TextInfo.ToTitleCase($lastNameNum.ToLower())
    Write-Host "Detected user:" $firstNameproper $lastNameProper $item.Value.ToLower()
    Start-Sleep -s 2

    $Emails = $item.Value.ToLower() # trim email address and set to lowercase

    Write-Host "Attempting to create user $Emails ...."
    #$user_exist = aws appstream describe-users --authentication-type USERPOOL | ConvertFrom-Json | Select -expand Users | Select UserName, Status | Export-CSV "C:\Users\Administrator\Downloads/data3.csv" -notypeinformation
    $user_exists = aws appstream describe-users --authentication-type USERPOOL | ConvertFrom-Json | Select -expand Users | Select UserName, Status
    $user_exists | Export-CSV "data3.csv" -notypeinformation
    $assoc_stacks = aws appstream describe-user-stack-associations --user-name $Emails --authentication-type USERPOOL | ConvertFrom-Json | Select -expand UserStackAssociations | Select StackName
    
    # Strip user account status
    Import-Csv -Path 'data3.csv' | Where-Object {
        $_.UserName -match $Emails
    } | Export-Csv -Path 'data4.csv' -NoTypeInformation

    # Pull Status
    Import-Csv -Path 'data4.csv' | Where-Object {$Status = $_.Status}

    # Check if user already exists, if not, check if Welcome Email can still be sent. Resend if so.
    if (($user_exists | Where-Object {$_.UserName -eq $Emails}) -And ($Status -eq "FORCE_CHANGE_PASSWORD")) {
        Write-Host "$Emails already exists but has not accepted their welcome email. Reissued email." -ForegroundColor Yellow
        aws appstream create-user --user-name $Emails --message-action "RESEND" --authentication-type USERPOOL
        $array_resend_welcome += $Emails
        $resendi++
        Start-Sleep -s 2 }
    
    # Check if user already exists and if assigned to stack.
    elseif (($user_exists | Where-Object {$_.UserName -eq $Emails}) -And ($assoc_stacks | where {$_.StackName -eq $Stack})) {
        Write-Host "User already has access" -ForegroundColor Red
        $array_already_exists += $Emails
        $existsi++
        Start-Sleep -s 2 }

    #check user is confirmed and not assigned to $Stack
    elseif (($user_exists | Where-Object {$_.UserName -eq $Emails}) -And ($assoc_stacks | where {$_.StackName -notlike $Stack})) {
        Write-Host "User exists and assigning to stack" -ForegroundColor Red
        aws appstream batch-associate-user-stack --user-stack-associations StackName=$Stack,UserName=$Emails,AuthenticationType="USERPOOL",SendEmailNotification=true  >$null 2>&1
        Write-Host "Associated user $Emails to stack $Stack" -ForegroundColor Green
        $array_assign += $Emails
        $assigni++
        Start-Sleep -s 2 }
    
    # Else, create user and associate with stack
    else {
        aws appstream create-user --user-name $Emails --first-name $firstNameProper --last-name $lastNameProper --authentication-type USERPOOL  >$null 2>&1
        Write-Host "Created user"$Emails -ForegroundColor Green
        Start-Sleep -s 2
        aws appstream batch-associate-user-stack --user-stack-associations StackName=$Stack,UserName=$Emails,AuthenticationType="USERPOOL",SendEmailNotification=true  >$null 2>&1
        Write-Host "Associated user $Emails to stack $Stack" -ForegroundColor Green
        $array_created += $Emails
        $createi++
        Start-Sleep -s 2
    }  
}

# Sets responses based on array values
$resends = $array_resend_welcome | ForEach-Object {$PSItem}
$exists = $array_already_exists | ForEach-Object {$PSItem}
$created = $array_created | ForEach-Object {$PSItem}
$assign = $array_assign | ForEach-Object {$PSItem}

# Create ticket response based on conditions
if (($resends -gt 0) -And ($exists -gt 0) -And ($created -gt 0)){
    $ticket_response = ""
elseif (($resends -gt 0) -And ($exists -gt 0)){
    $ticket_response = ""
elseif (($resends -gt 0) -And ($created -gt 0)){
    $ticket_response = "Hello, An Amazon AppStream welcome email has been reissued to the following user(s): $resends. The follwing user(s) have now been created as per your request: $created. Please note that login details to AppStream are case sensitive and were created in lower case. Please have the user(s) sign in using the new temporary password in this email within the next 7 days."}
elseif (($create -gt 0) -And ($assign -gt 0)){
    $ticket_response = ""
elseif (($resends -gt 0) -And ($assign -gt 0)){
    $ticket_response = ""
elseif (($created -gt 0) -And ($exists -gt 0)){
    $ticket_response = ""
elseif ($resends -gt 0){
    $ticket_response = "Hello, An Amazon AppStream welcome email has been reissued to the following user(s): $resends. Please have the user sign in using the new temporary password in this email within the next 7 days, as it does expire after this period of time. I will close out this ticket for now. However, should you require any further assistance regarding the user(s) above please comment on this ticket and the issue will be reopened."}
# If only new users were created
elseif ($created -gt 0) {
    $ticket_response = ""
# If users already existed
elseif ($exists -gt 0) {
    $ticket_response = ""
elseif ($assign -gt 0) {
    $ticket_response = ""
    
# Respond to ticket
Add-JiraIssueComment -Comment $ticket_response -Issue $ticket -Credential $Credential >$null 2>&1
Stop-Transcript >$null 2>&1
