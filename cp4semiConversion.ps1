$ErrorActionPreference = "Stop"

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
    $logFile = "C:\Temp\cp4semiConversion.log"

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

$systemID = $args[0]
$token = $args[1]

$APIHost='api.level27.eu'
$chefendpoint='https://chef.level27.eu/organizations/level27'

# The conversion generates its own queue token locally and hands it to CP4.
$queueToken = -join ((0x30..0x39) + (0x41..0x5A) + (0x61..0x7A) | Get-Random -Count 30 | ForEach-Object {[char]$_})

$payload = @{
    "token" = $queueToken
} | ConvertTo-Json
$headers = @{"Authorization" = $token}

# Install Chef before converting, so a failed install leaves the system untouched and the script can be rerun
$installed = (Get-WMIObject -Query "SELECT * FROM Win32_Product Where Name Like 'Chef Infra Client%'").Length -gt 0
if ( $installed ){
    Write-LogMessage -LogType INFO -ToUser -Message "Chef already installed"
}else{
    Write-LogMessage -LogType INFO -ToUser -Message "Chef install started"
    try{
        # Chef's install.ps1 sets [Console]::OutputEncoding inside its module, which throws "The handle is invalid"
        # without a console and aborts loading the module (so 'install' is never defined); strip that line
        $chefInstallScript = (Invoke-WebRequest -UseBasicParsing https://omnitruck.chef.io/install.ps1).Content
        $chefInstallScript = $chefInstallScript -replace '(?m)^\s*\[Console\]::OutputEncoding\s*=.*$', ''
        $chefInstallScript | Invoke-Expression; install -version 18.3.0
    }catch{
        Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef install failed"
        Write-LogMessage -LogType CRITICAL -Message "Exit"
        throw $_
    }
    if(-not (Test-Path C:\opscode\chef\bin\chef-client.bat)){
        Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef install failed: chef-client not found after install"
        Write-LogMessage -LogType CRITICAL -Message "Exit"
        throw "Chef install failed"
    }
    Write-LogMessage -LogType INFO -ToUser -Message "Chef install success"
}

Write-LogMessage -LogType INFO -ToUser -Message "Doing first call to API..."
Write-LogMessage -LogType INFO -Message "L27 init $apihost (POST: systems/$systemID/convert/type/kvmguest)"

try{
    Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/$systemID/convert/type/kvmguest`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    $data = Invoke-RestMethod -Uri "https://$APIHost/v1/systems/$systemID/convert/type/kvmguest" -Method Post -Body $payload -Headers $headers -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
}catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/$systemID/convert/type/kvmguest`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
}

Write-LogMessage -LogType INFO -Message "Result: $data"

# The convert call returns the chef client key and queue host directly (top-level, not under 'system').
$chefClientKey = $data.chefClientKey
$chefQueue = $data.host

# CP4 creates the chef client and node under the system UID, so it must come from the API.
$systemUID = $data.uid

# Fetch the FQDN of the (already existing) system for the firstboot config.
try{
    Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/$systemID`" -Method Get -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    $systemData = Invoke-RestMethod -Uri "https://$APIHost/v1/systems/$systemID" -Method Get -Headers $headers -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
}catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"https://$APIHost/v1/systems/$systemID`" -Method Get -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
}
$systemFQDN = $systemData.system.fqdn

Write-LogMessage -LogType INFO -ToUser -Message "System is created at Level27, now proceeding with install"

#setup chef
New-Item C:\Chef\client.pem -Value $chefClientKey -ItemType File -Force

New-Item C:\Chef\client.rb -ItemType File -Force -Value @"
chef_server_url  "$chefendpoint"
node_name "$systemUID"
chef_license 'accept'
migrate_key_to_keystore false
auth_key_registry_type 'user'
"@ | Out-Null

New-Item -Path C:\Chef -Name firstboot.json -ItemType File -Force -Value @"
{
    "system": {
        "fqdn": "$systemFQDN"
    },
    "l27cp4": {
		"system_uid": "$systemUID",
		"system_token": "$queueToken",
		"system_queue": "$chefQueue",
		"system_api": "https://$APIHost"
	}
}
"@ | Out-Null

Write-LogMessage -LogType INFO -ToUser -Message "Starting initial Chef run"
Start-Sleep -Seconds 2
try{
    & C:\opscode\chef\bin\chef-client.bat -j C:\chef\firstboot.json -o l27wcp4
}catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef run failed"
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
}

while ((Get-Service 'CP4Worker').status -ne "Running"){
    Start-Sleep -Seconds 1
    Write-LogMessage -ToUser -LogType INFO -Message "Waiting for CP4Worker to start"
}

Write-LogMessage -ToUser -LogType INFO -Message "This conversion is done, see https://$APIHost/systems/$systemID"
