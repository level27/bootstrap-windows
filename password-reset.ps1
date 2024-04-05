function get-randompass {
  $Response=(Invoke-WebRequest -useb "https://win-pw.level27.eu/rnd.php")
  if ($Response.StatusCode -eq 200) {
    return $Response.Content
  }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Output "Start Script"

# Are we Domain controller?
if(Get-WmiObject -Query "select * from Win32_OperatingSystem where ProductType='2'"){
  # if so, please abort
  exit 0
}

$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]
$passAdmin=get-randompass
$passL27=get-randompass

if ($passL27.length -ne 17 -and $passAdmin.length -ne 17){
  Write-Output "Password length not OK"
  # something is wrong, abort
  exit 1
}

"$uid;$passAdmin;$passL27" | Out-File C:\l27\cp4\passwords.txt

$postParams = @{uid=$uid;passAdmin=$passAdmin;passL27=$passL27}
$response = Invoke-WebRequest -useb -Uri https://win-pw.level27.eu/post.php -Method POST -Body $postParams| Out-Null

#we only continue if post is OK
if ($response.StatusCode -ne 200){
  Write-Output "POST not OK"
  Write-Output $response.StatusCode
  # something is wrong, abort
  exit 1
}


$pass=$passL27 | ConvertTo-SecureString -AsPlainText -Force
if(Get-localuser -name level27admin){
  Write-Output "Modify L27 user"
  Set-LocalUser -Name level27Admin -Password $pass
} else {
  Write-Output "New L27 user"
  New-LocalUser -Name level27Admin -Password $pass -AccountNeverExpires
  Add-LocalGroupMember -Group Administrators -Member level27Admin
}

Write-Output "Set Administrator user"
# Set new Administrator password
$pass=$passAdmin | ConvertTo-SecureString -AsPlainText -Force
Set-LocalUser -Name Administrator -Password $pass

Write-Output "Done"
