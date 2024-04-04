$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]
$passAdmin=(Invoke-WebRequest https://win-pw.level27.eu/rnd.php).content
$passL27=(Invoke-WebRequest https://win-pw.level27.eu/rnd.php).content

"$uid;$passAdmin;$passL27" | Out-File C:\test.txt
Write-Output $uid
Write-Output $passAdmin
