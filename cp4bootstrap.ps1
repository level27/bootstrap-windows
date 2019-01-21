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
    $logFile = "C:\Temp\cp4import.log"

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

$organisationID = $args[0]
$token = $args[1]

$APIHost = "api.cp4dev.be"
$chefendpoint = "https://chef.cp4dev.be/organizations/level27"
$hostname = $env:COMPUTERNAME
$payload = @{
    "organisation" = $organisationID
    "name" = $hostname
} | ConvertTo-Json
$headers = @{"Authorization" = $token}

Write-LogMessage -LogType INFO -ToUser -Message "Doing first call to API..."
Write-LogMessage -LogType INFO -Message "L27 init $apihost (POST: systems/import)"

try{
    Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/import`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    $data = Invoke-RestMethod -Uri "http://$APIHost/v1/systems/import" -Method Post -Body $payload -Headers $headers -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
}catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/import`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
}

Write-LogMessage -LogType INFO -Message "Result: $($data.system)"

$systemID = $data.system.id
$systemUID = $data.system.uid
$systemStatus = $data.system.status

#Wait for CP4 to create the system
Start-Sleep -Seconds 3
try{
    Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/$systemID/import`" -Method Get -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    $data = Invoke-RestMethod -Uri "http://$APIHost/v1/systems/$systemID/import" -Method Get -Headers $headers -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
}catch{
    Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/$systemID/import`" -Method Get -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
    Write-LogMessage -LogType CRITICAL -Message "Exit"
    throw $_
}

Write-LogMessage -LogType INFO -Message "Result: $($data.system)"

$systemStatus = $data.system.status
$queueToken = $data.system.token
$chefClientKey = $data.system.chefClientKey
$chefQueue = $data.system.chefQueue
#$chefAPI = $data.system.chefApi

if($systemStatus -eq "importing"){
    Write-LogMessage -LogType INFO -Message "Importing" -ToUser
    
    try{
        #install Chef
        Write-LogMessage -LogType INFO -ToUser -Message "Chef install started"
        . { Invoke-WebRequest -useb https://omnitruck.chef.io/install.ps1 } | Invoke-Expression; install
        Write-LogMessage -LogType INFO -ToUser -Message "Chef install success"
    }catch{
        Write-LogMessage -LogType CRITICAL -ToUser -Message "Chef install failed"
        Write-LogMessage -LogType CRITICAL -Message "Exit"
        throw $_
    }
    
    #setup chef
    New-Item C:\Chef\client.pem -Value $chefClientKey -ItemType File -Force

    New-Item C:\Chef\client.rb -ItemType File -Value @"
chef_server_url  "$chefendpoint"
node_name "$systemUID"
"@ -Force | Out-Null

    New-Item -Path C:\Chef -Name firstboot.json -ItemType File -Value @"
{
    "l27wcp4": {
		"system_uid": "$systemUID",
		"system_token": "$queueToken",
		"system_queue": "$chefQueue",
		"system_api": "http://$APIHost"
	}
}
"@ -Force | Out-Null

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

    Start-Sleep -Seconds 3
    #report import done
    $payload = @{"status" = "done"} | ConvertTo-Json
    try{
        Write-LogMessage -LogType INFO -Message "Execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/$systemID/importdone`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
        $data = Invoke-RestMethod -Uri "http://$APIHost/v1/systems/$systemID/importdone" -Method Post -Body $payload -Headers $headers -UserAgent "L27Bootstrap/0.1" -ContentType "application/json"
        Write-LogMessage -ToUser -LogType INFO -Message "Done: $($data)"
    }catch{
        Write-LogMessage -LogType CRITICAL -ToUser -Message "Failed to execute Invoke-RestMethod -Uri `"http://$APIHost/v1/systems/$systemID/importdone`" -Method Post -Body $payload -Headers $headers -UserAgent `"L27Bootstrap/0.1`" -ContentType `"application/json`""
        Write-LogMessage -LogType CRITICAL -Message "Exit"
        throw $_
    }
} else {
    # Log fail
}
