function get-randompass{
  $Response=(Invoke-WebRequest -useb "https://win-pw.level27.eu/rnd.php")
  if ($Response.StatusCode -eq 200) {
    return $Response.Content
  }
}

$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]
$passAdmin=get-randompass

#try
#{
#    $Response=(Invoke-WebRequest -useb "https://win-pw.level27.eu/rnd.php").content
#    # This will only execute if the Invoke-WebRequest is successful.
#    $StatusCode = $Response.StatusCode
#} catch {
#    Write-Output $_.Exception
#}
#Write-Output $StatusCode

$passL27=get-randompass

"$uid;$passAdmin;$passL27" | Out-File C:\l27\cp4\passwords.txt

$postParams = @{uid=$uid;passAdmin=$passAdmin;passL27=$passL27}
Invoke-WebRequest -useb -Uri https://win-pw.level27.eu/post.php -Method POST -Body $postParams

Write-Output $uid
