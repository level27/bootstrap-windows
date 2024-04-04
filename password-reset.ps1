function get-randompass {
  $Response=(Invoke-WebRequest -useb "https://win-pw.level27.eu/rnd.php")
  if ($Response.StatusCode -eq 200) {
    return $Response.Content
  }
}

$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]
$passAdmin=get-randompass
$passL27=get-randompass

if ($passL27.length -ne 17 && $passAdmin.length -ne 17){
  Write-Host "Password length not OK"
  # something is wrong, abort
  exit 1
}

"$uid;$passAdmin;$passL27" | Out-File C:\l27\cp4\passwords.txt

$postParams = @{uid=$uid;passAdmin=$passAdmin;passL27=$passL27}
$response = Invoke-WebRequest -useb -Uri https://win-pw.level27.eu/post.php -Method POST -Body $postParams

#we only continue if post is OK
if (response.StatusCode -ne 200){
  Write-Host "POST not OK"
  # something is wrong, abort
  exit 1
}

# Create a new Admin user for emergencies
$pass=$passL27 | ConvertTo-SecureString -AsPlainText -Force
New-LocalUser -Name level27Admin -Password $pass -AccountNeverExpires
Add-LocalGroupMember -Group Administrators -Member level27

# Set new Administrator password
$pass=$passAdmin | ConvertTo-SecureString -AsPlainText -Force
Set-LocalUser -Name Administrator -Password $pass

Write-Host "Done"
