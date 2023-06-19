#requires -version 4
<#
.SYNOPSIS
  Script bootstraps system with CP4
.DESCRIPTION
  When installing a new system using CP4 (the best control panel ever created) this script makes sure that:
  - The system is registered to the control panel
  - Chef is installed
  - Chef is run
  This script will only work when the system is in the autoinstall vlan of CP4 datacenter
.INPUTS
  None
.OUTPUTS
  Log file stored in C:\Temp\cp4bootstrap.log
.NOTES
  Version:        1.0
  Author:         Roeland Andelhofs
  Creation Date:  02/09/2021
  Purpose/Change: Initial script development
  
.EXAMPLE
  .\cp4bootstrap.ps1
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------
$ErrorActionPreference = "Stop"

#----------------------------------------------------------[Declarations]----------------------------------------------------------
$queueToken   = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
$APIHost      = $env:L27_API_HOST
$chefendpoint = $env:L27_CHEF_HOST
$systemQueue  = $env:L27_Q_HOST

#-----------------------------------------------------------[Functions]------------------------------------------------------------
function Get-NetworkConfig {
  Get-WmiObject Win32_NetworkAdapter -Filter 'NetConnectionStatus=2' |
  ForEach-Object {
      $result = 1 | Select-Object Name, IP, MAC
      $result.Name = $_.Name
      $result.MAC = $_.MacAddress
      $config = $_.GetRelated('Win32_NetworkAdapterConfiguration') 
      $result.IP = $config | Select-Object -expand IPAddress
      $result
  }
}

Function Write-LogMessage{
  Param(
    [parameter(Mandatory=$false)]
    [switch]
    $ToUser = $false,
    [parameter(Mandatory=$true)]
    [String]
    $Message,
    [Parameter(mandatory=$true)]
    [ValidateSet('INFO', 'WARNING', 'CRITICAL')]
    $LogType
  )

  $time = Get-Date -Format u
  $data = "$time : $LogType - $Message"
  $logFile = "$($env:WinDir)\temp\cp4bootstrap.log"

  if(-not (Test-Path $logFile)){
    New-Item -ItemType File $logFile -Force  | Out-Null
  }

  if($ToUser){
    $color = switch ($LogType)
    {
      'INFO'      { "white"   }
      'WARNING'   { "yellow"  }
      'CRITICAL'  { "red"     }
    }
    Write-Host $data -ForegroundColor $color 
  }
  Add-Content -Path $logFile -Value $data
}

Function Send-AutoinstallFeedback{
  Param(
    [parameter(Mandatory=$true)]
    [string]
    $MacAddress,
    [parameter(Mandatory=$false)]
    [string]
    $Token = "",
    [parameter(Mandatory=$true)]
    [bool]
    $Success
  )

  $payload = 
    @{
      "mac"   = $MacAddress
      "token" = $Token
      "result" = $Success
    } | ConvertTo-Json

  # Let CP4 know the status of the autoinstall
  try{
    Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/autoinstall`" -Method Post -Body $payload -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    $data = Invoke-RestMethod -Uri "https://$APIHost/v1/systems/autoinstall" -Method Post -Body $payload -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
  }catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/autoinstall`" -Method Post -Body $payload -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
  }

  return $data
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------
Write-LogMessage -LogType INFO -ToUser -Message "Starting CP4 bootstrap"
# Stop cp4worker that was installed in the build
Get-Service cp4worker -Erroraction SilentlyContinue | Stop-Service

# Get MAC address
$NetworkInfo = Get-NetworkConfig
$mac = $NetworkInfo.MAC.tostring()

Write-LogMessage -LogType INFO -ToUser -Message "Doing first call to API..."
Write-LogMessage -LogType INFO -Message "L27 init $APIHost (POST: systems/autoinstall)"
Write-LogMessage -LogType INFO -Message "Registering with dataset: mac = $mac and secret token $($queueToken)"

$data = Send-AutoinstallFeedback -MacAddress $mac -Token $queueToken -Success $true

Write-LogMessage -LogType INFO -Message "Result: $($data)"

$systemUID = $data.uid
$chefClientKey = $data.chefClientKey

#Wait for CP4 to create the system
Start-Sleep -Seconds 3

# Install Chef, if not already installed
$installed = (Get-WMIObject -Query "SELECT * FROM Win32_Product Where Name Like 'Chef Infra Client%'").Length -gt 0
if ( $installed ){
  Write-LogMessage -LogType INFO -ToUser -Message "Chef already installed"
}else{
  Write-LogMessage -LogType INFO -ToUser -Message "Chef install started"
  try{
    . { Invoke-WebRequest -useb https://omnitruck.chef.io/install.ps1 } | Invoke-Expression; install -version 17
    Write-LogMessage -LogType INFO -ToUser -Message "Chef install success"
  }catch{
    Send-AutoinstallFeedback -MacAddress $mac -Success $false
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef install failed"
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
  }
}

#setup chef
New-Item C:\Chef\client.pem -Value $chefClientKey -ItemType File -Force

New-Item C:\Chef\client.rb -ItemType File -Force -Value @"
chef_server_url  "$chefendpoint"
node_name "$systemUID"
chef_license 'accept'
migrate_key_to_keystore false
auth_key_registry_type user
"@ | Out-Null

New-Item -Path C:\Chef -Name firstboot.json -ItemType File -Force -Value @"
{
  "l27cp4": {
    "system_uid": "$systemUID",
    "system_token": "$queueToken",
    "system_queue": "$systemQueue",
    "system_api": "https://$APIHost"
  }
}
"@ | Out-Null

Write-LogMessage -LogType INFO -ToUser -Message "Starting initial Chef run"
Start-Sleep -Seconds 2
try{
    & C:\opscode\chef\bin\chef-client.bat -j C:\chef\firstboot.json -o l27wcp4
}catch{
  Send-AutoinstallFeedback -MacAddress $mac -Success $false
  Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef run failed"
  Write-LogMessage -LogType CRITICAL -Message "Exit"
  throw $_
}

Remove-Item C:\chef\firstboot.json

New-Item C:\L27\CP4\token.ini -ItemType File -Force -Value @"
[cp4]
token=$queueToken
"@ | Out-Null

Write-LogMessage -ToUser -LogType INFO -Message "Waiting for CP4Worker to start"
while ((Get-Service 'CP4Worker').status -ne "Running"){
  Write-LogMessage -ToUser -LogType INFO -Message "CP4Worker not yet running, sleeping for 1 second"
  Start-Sleep -Seconds 1
}

Write-LogMessage -ToUser -LogType INFO -Message "CP4Worker running"
Write-LogMessage -ToUser -LogType INFO -Message "Bootstrap finished"
Start-Sleep -Seconds 10
