# AppStream 2.0 Remote Programmatic Image Creation Script
# Start script by using the following command ‘.\Create-Image.ps1 -SourceFile C:\Source\ApplicationList.csv -ComputerName [Image Name] -s3bucket appdeployment'
param(
    [Parameter(Mandatory = $true,
        HelpMessage = "Full path to CSV file EG: C:\Source\ApplicationList.csv")]
    [string]$SourceFile,

    [Parameter(Mandatory = $true,
        ValueFromPipeline = $True,
        HelpMessage = "Image Builder Name")]
    [string[]]$ComputerName,
    
    [Parameter(HelpMessage = "S3 Bucket that Installers are stored in. This is case sensitive.")]
    [string]$s3bucket
)

$CSV = Import-Csv -Delimiter "," -Path $SourceFile
$exePath = "C:\Program Files\Amazon\Photon\ConsoleImageBuilder"
$user = "ImageBuild"
$pass = convertto-securestring -String "Password1" -AsPlainText -Force 
$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $pass
#$credential = Get-Credential

if ($ComputerName -eq "Image_Builder_UK")
{
    aws configure set region eu-west-1
    $setRegion = "eu-west-1"
    }
elseif ($ComputerName -eq "Image_Builder_US")
{
    aws configure set region us-east-1
    $setRegion = "us-east-1"
    }

Start-Sleep -s 1

# Find all apps in s3 and prep them for listbox
$s3_list = aws s3api list-objects --bucket "appdeployment" | ConvertFrom-Json | Select -expand Contents | Select Key
[int]$app_count = $s3_list.Count
$appcount = 0
$s3_new = $s3_list -replace '@{Key=Desktop.Application.v',''
$s3_apps = $s3_new -replace '.exe}',''

# Find all fleets existing and prep them for listbox
$all_fleets = aws appstream describe-fleets | ConvertFrom-Json | Select -expand Fleets | Select Name
[int]$fleets_count = $all_fleets.Count
$icount = 0
$fleets_new = $all_fleets -replace '@{Name=',''
$fleets = $fleets_new -replace '}',''

# UI for select Client
# Allows user to select version to install
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Select version'
$form.Size = New-Object System.Drawing.Size(470,300)
$form.StartPosition = 'CenterScreen'

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Point(190,220)
$OKButton.Size = New-Object System.Drawing.Size(75,23)
$OKButton.Text = 'OK'
$OKButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $OKButton
$form.Controls.Add($OKButton)

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(10,20)
$label.Size = New-Object System.Drawing.Size(280,20)
$label.Text = 'Select Client:'
$form.Controls.Add($label)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(10,40)
$listBox.Size = New-Object System.Drawing.Size(260,20)
$listBox.Height = 170

#box for versioning
$label2 = New-Object System.Windows.Forms.Label
$label2.Location = New-Object System.Drawing.Point(320,20)
$label2.Size = New-Object System.Drawing.Size(380,20)
$label2.Text = 'Select version:'
$form.Controls.Add($label2)

$listBox2 = New-Object System.Windows.Forms.ListBox
$listBox2.Location = New-Object System.Drawing.Point(320,40)
$listBox2.Size = New-Object System.Drawing.Size(120,20)
$listBox2.Height = 170

# list of clients
while ($icount -lt $fleets_count) {
    [void] $listBox.Items.Add($fleets[$icount])
    $icount++
    }

# list of genesis apps
while ($appcount -lt $app_count) {
    [void] $listBox2.Items.Add($s3_apps[$appcount])
    $appcount++
    }

$form.Controls.Add($listBox)
$form.Controls.Add($listBox2)

$form.Topmost = $true

$result = $form.ShowDialog()

if ($result -eq [System.Windows.Forms.DialogResult]::OK)
{
    $x = $listBox.SelectedItem
    $x2 = $listBox2.SelectedItem

$app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
$previous_fleet_image = aws appstream describe-fleets --names $x | ConvertFrom-Json | Select -expand Fleets | Select ImageName
$delete_image = $previous_fleet_image -replace '@{ImageName=',''
$delete_previous_image = $delete_image -replace '}',''


#Rename ApplicationList.csv to download relevant .exe file
Import-Csv -Path 'C:\Source\ApplicationList.csv' | ForEach-Object {
    $_.InstallerPath = "C:\Source\Software\Genesis\Desktop.Application.v" +$x2+ ".exe"
    $_
} | Export-Csv -Path 'C:\Source\ApplicationList1.csv' -NoTypeInformation
Remove-Item -Path 'C:\Source\ApplicationList.csv'
Rename-Item -Path 'C:\Source\ApplicationList1.csv' -NewName 'C:\Source\ApplicationList.csv'

Start-Sleep -s 5

# Stop Image if started
while ($app_state -match "Running"){
 aws appstream stop-image-builder --name $ComputerName >$null 2>&1
 write-host "Stopping up $ComputerName Image..."
 Start-Sleep -s 5
 $app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
 }

# Start Image if stopped
if ($app_state -match "Stopped"){
 aws appstream start-image-builder --name $ComputerName >$null 2>&1
 write-host "Starting up $ComputerName Image..."
 Start-Sleep -s 5

# Pause while waiting for image to run
$app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
while ($app_state -match "Pending"){
    Start-Sleep -s 15
    write-host "$ComputerName starting up.."
    $app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
}

$app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
while ($app_state -match "Updating Agent"){
    Start-Sleep -s 15
    write-host "Image updating.."
    $app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
}

#Run when image is in running state
$app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
if ($app_state -match "Running"){


foreach ($Computer in $ComputerName) {
    $IBQuery = Get-APSImageBuilderList -name $Computer -region $setRegion
    $IBIP = $IBQuery.NetworkAccessConfiguration.EniPrivateIpAddress
    $session = New-PSSession -ComputerName $IBIP -Credential $Credential

    foreach ($App in $CSV) {
        #AppStream's Image Assistant Required Parameters
        $AppName = $App.Name
        $Params = " --name " + $AppName + " --absolute-app-path " + $App.LaunchPath     
        #AppStream's Image Assistant Optional Parameters
        if ($App.DisplayName) { $Params += " --display-name " + $App.DisplayName }
        if ($App.WorkingDir) { $Params += " --working-directory " + $App.WorkingDir }
        if ($App.IconPath) { $Params += " --absolute-icon-path " + $App.IconPath }      
        if ($App.LaunchParameters) { $Params += " --launch-parameters " + $App.LaunchParameters }     
        if ($App.ManifestPath) { $Params += " --absolute-manifest-path " + $App.ManifestPath }

        #Download and Install applicatoin to Image Builder
        if ($App.InstallerPath) {
            $InstallerPath = $App.InstallerPath
            $exeName = Split-Path -Path $InstallerPath -Leaf
            $exeFolder = Split-Path -Path $InstallerPath
            

            if ($s3bucket) {
                $s3presigned = "Get-S3PresignedURL -BucketName " + $s3bucket + " -Key " + $exeName + " -Expires (Get-Date).AddDays(30)"
                $s3url = Invoke-Expression $s3presigned
                Invoke-Command -Session $session -ScriptBlock {
                    $scriptName = "EnvVariables.ps1"
                    if (Test-Path -Path "C:\script\$scriptName"){
                        Remove-Item "C:\script\$scriptName" -Force -Recurse >$null 2>&1 } 
   
                    $gen_app = Get-WmiObject Win32_Product -Filter "Name = 'Application'"
                    $gen_app.Uninstall() >$null 2>&1
                    Write-Host "Uninstalled Application"
                    New-Item -ItemType "directory" -Path $using:exeFolder -Force | Out-Null 
                    Write-Host "Downloading $using:exeName to $using:exeFolder"
                    Invoke-WebRequest -Uri $using:s3url -OutFile $using:InstallerPath
                    Write-Host "Installing $using:AppName..." 
                    Start-Process -FilePath $using:InstallerPath -Verb runAs -ArgumentList /quiet -Passthru -Wait >$null 2>&1
                    Write-Host "Created System Environmental variables.."
                }
            }
        }
        #Use AppStream's Image Assistant API to add applications
        Invoke-Command -Session $session -ScriptBlock {
            Set-Location $using:exePath
            $RemAppCMD = '.\image-assistant.exe remove-application --name "Genesis"'
            $AddAppCMD = '.\image-assistant.exe add-application ' + $using:Params
            $RemApp = Invoke-Expression  $RemAppCMD | ConvertFrom-Json 
            $AddApp = Invoke-Expression  $AddAppCMD | ConvertFrom-Json
            if ($RemApp.status -eq 0) {
                Write-Host "Removed old $using:AppName catalog"
            } else {
                Write-Host "ERROR removing $using:AppName" 
                Write-Host $RemApp.message
            }
            if ($AddApp.status -eq 0) {
                Write-Host "Added new $using:AppName catalog"
            } else {
                Write-Host "ERROR adding $using:AppName" 
                Write-Host $AddApp.message
            }
        }
    }
    #Use AppStream's Image Assistant API to create image
    Start-Sleep -s 20
    $ImageName = $x + "_" + $x2
    Invoke-Command -Session $session -ScriptBlock {
        Set-Location $using:exePath
        $CreateCMD = '.\image-assistant.exe create-image --name ' + $using:ImageName 
        $Create = Invoke-Expression $CreateCMD | ConvertFrom-Json
        if ($Create.status -eq 0) {
            Write-Host "Successfully started creating image $using:ImageName"
        } else {
            Write-Host "ERROR creating Image $using:ImageName"
            Write-Host "$Create.message"
        }
    }
    Remove-PSSession $session
}
}
}
}

Start-Sleep -s 10
# Image snapshotting
$app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
while ($app_state -match "Snapshotting"){
    Start-Sleep -s 30
    write-host "Image snapshotting.."
    $app_state = aws appstream describe-image-builders --names $ComputerName | ConvertFrom-Json | Select -expand ImageBuilders | Select State
}

# Fleet 
$app_image_reg = aws appstream describe-images --names $ImageName | ConvertFrom-Json | Select -expand Images | Select State
if ($app_image_reg -match "Available"){ 
    aws appstream stop-fleet --name $x
    $app_fleet = aws appstream describe-fleets --names $x | ConvertFrom-Json | Select -expand Fleets | Select State
    Start-Sleep -s 5
    while ($app_fleet -match "Stopping"){
        Start-Sleep -s 30
        write-host "Waiting for Fleet to stop.."
        $app_fleet = aws appstream describe-fleets --names $x | ConvertFrom-Json | Select -expand Fleets | Select State
    }
    aws appstream update-fleet --image-name $ImageName --name $x >$null 2>&1
    write-host "Updated $x with image $ImageName"
    Start-Sleep -s 5
    aws appstream start-fleet --name $x  >$null 2>&1

    Start-Sleep -s 5
    $app_fleet = aws appstream describe-fleets --names $x | ConvertFrom-Json | Select -expand Fleets | Select State
    while ($app_fleet -match "Starting"){
        Start-Sleep -s 30
        write-host "Waiting for Fleet to start.."
        $app_fleet = aws appstream describe-fleets --names $x | ConvertFrom-Json | Select -expand Fleets | Select State
    }
    
# Build stack and associate
Write-Host "Associating stack to fleet.."
aws appstream associate-fleet --fleet-name $x --stack-name $x  >$null 2>&1
Start-Sleep -s 5
Write-Host "Removing previous image $delete_previous_image"
aws appstream delete-image --name $delete_previous_image >$null 2>&1
Start-Sleep -s 5
Write-Host "Successfully updated $x AppStream"
}
