$global:hostname = ""
$global:renamed = false

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
    $logFile = "C:\Temp\cp3bootstrap.log"

    if(-not (Test-Path $logFile)){
        New-Item -ItemType Directory -Path C:\ -Name Temp -Force | Out-Null
        New-Item -ItemType File -Path C:\Temp -Name cp3bootstrap.log -Force  | Out-Null
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

Function Request-JSON {
    Param(
        [Parameter(Mandatory=$True)]
        [hashtable]$Params,
        [int]$Retries = 10,
        [int]$SecondsDelay = 3
    )

    $Params.Add('UserAgent', 'WinCP3Bootstrap')

    $url = $Params['Uri']

    $cmd = { Invoke-WebRequest @Params }

    $retryCount = 0
    $completed = $false
    $response = $null

    while (-not $completed) {
        try {
            $response = Invoke-Command $cmd -ArgumentList $Params
            if ($response.StatusCode -ne 200) {
                Write-Warning "Expecting reponse code 200, was: $($response.StatusCode)"
                throw "Expecting reponse code 200, was: $($response.StatusCode)"
            }
            $completed = $true
        } catch {
            Write-LogMessage -LogType WARNING -ToUser -Message "Request to $url failed. $_"
            if ($retrycount -ge $Retries) {
                Write-Error "Request to $url failed the maximum number of $retryCount times."
                throw
            } else {
                Write-Error "Request to $url failed. Retrying in $SecondsDelay seconds."
                Start-Sleep $SecondsDelay
                $retrycount++
            }
        }
    }

    Write-Host "OK: ($($response.StatusCode))"
    return ($response | ConvertFrom-Json )
}

Write-LogMessage -LogType WARNING -ToUser -Message 'CP3 INSTALLATION PROCESS. DO NOT TOUCH YOUR SERVER UNTIL YOU SEE THE LOGIN PROMPT'

$NetworkInfo = Get-NetworkConfig

#only get IPv4 address
$ip = ( $NetworkInfo.IP | Where-Object { $_ -match "\d{1,3}(\.\d{1,3}){3}" } ).tostring()
$mac = $NetworkInfo.MAC.tostring()

Write-LogMessage -LogType INFO -ToUser -Message "IP = $ip"
Write-LogMessage -LogType INFO -ToUser -Message "Mac = $mac"

$baseurl = 'https://cp3.level27.be'
if (($ip -like "172.21*") -or ($ip -like "172.30*")) {
	$baseurl = 'http://cp3.yope.be'
}

Write-LogMessage -LogType INFO -ToUser -Message "BaseURL = $baseurl"

while (!((Invoke-WebRequest $baseurl -UseBasicParsing).StatusCode -eq 200)){
    Write-LogMessage -LogType WARNING -ToUser -Message "No valifd answer from $baseurl, waiting 5 seconds to try again"
    Start-Sleep 5
}

#Announce and Bootstrap
$ip = [uri]::EscapeDataString($ip)
$mac = [uri]::EscapeDataString($mac)

$url = "$baseurl/mvc/project/autoinstall/bootstrap?cp3=awesome&ip=$ip&mac=$mac"

Write-LogMessage -LogType INFO -ToUser -Message "Announcing myself on $url"

$result = Request-JSON -Params @{'Method'='GET'; 'Uri' =$url}

if (-not ($result.success -eq "True")) {
    Write-LogMessage -LogType CRITICAL -ToUser -Message "No luck chuck"
    throw "KAPOT!"
}else{
    $max_time = 3600 #600
	$elapsed_time = 0
    $done = $false
    
	while (($elapsed_time -lt $max_time) -and -not $done) {
		if (($result.success -eq "True") -and $result.job_status -eq 10) {
            Write-LogMessage -LogType INFO -ToUser -Message "Server said `"$($result.messages.global)`".  Job is waiting. Standing by."
            
            if( !($global:renamed) ){
                
                $fqdn = $result.fqdn
                $global:hostname = $fqdn.split('.')[0]

                Write-LogMessage -LogType INFO -ToUser -Message "Renaming server to $hostname"
                netdom renamecomputer $env:COMPUTERNAME /newname:"$hostname" /force | Out-Null
                netdom computername $env:COMPUTERNAME /add:"$fqdn" | Out-Null
                netdom computername $env:COMPUTERNAME /makeprimary:"$fqdn" | Out-Null
                $global:renamed = true
            }
		}
		elseif (($result.success -eq "True") -and ($result.job_status -eq 30)) {
            Write-LogMessage -LogType INFO -ToUser -Message "Server said `"$($result.messages.global)`".  Job is busy now. Standing by."
            
        }
		elseif (($result.success -eq "True") -and ($result.job_status -eq  50)) {
            Write-LogMessage -LogType INFO -ToUser -Message "Server said `"$($result.messages.global)`".  Job is done."
            $done = $true;
        }
		else {
            Write-LogMessage -LogType CRITICAL -ToUser -Message "Someting bad happened: $($result.messages.global)"
            throw "KAPOT!"
        }
        
        Start-Sleep -s 5
        $elapsed_time += 10;
        $result = Request-JSON -Params @{'Method'='GET'; 'Uri' =$url} 
	}
	if (-not $done) {
        Write-LogMessage -LogType CRITICAL -ToUser -Message "Could not do the bootstrap! Server did not respond in time"
	}
}

$cert = New-SelfSignedCertificate -DnsName $global:hostname -CertStoreLocation cert:\LocalMachine\My
Invoke-Expression "winrm delete winrm/config/listener?Transport=HTTPS+Address=*" -ErrorAction SilentlyContinue
winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$($global:hostname)`";CertificateThumbprint=`"$($cert.ThumbPrint)`"}"
Set-Item -Path WSMan:\localhost\Service\Auth\Certificate -Value $true
New-NetFirewallRule -DisplayName 'Windows Remote Management (HTTPS-In)' `
    -Name 'Windows Remote Management (HTTPS-In)' `
    -Direction Inbound -Action Allow `
    -Profile Any -LocalPort 5986 -Protocol TCP -RemoteAddress Any

winrm delete winrm/config/Listener?Address=*+Transport=HTTP

& C:\opscode\chef\bin\chef-client.bat -o l27wbase

schtasks.exe /create /f /tn cp3networks /ru SYSTEM /sc ONSTART /tr "powershell.exe -executionpolicy remotesigned -command '. C:\L27\CP3\bin\Set-Networks.ps1 ; schtasks.exe /delete /f /tn cp3networks'"

Write-LogMessage -LogType INFO -ToUser -Message "Bootstrap done, requesting CP3 to reboot."
$url = "$baseurl/mvc/project/autoinstall/reboot?cp3=awesome&mac=$mac"
$result = Request-JSON -Params @{'Method'='GET'; 'Uri' =$url}
