$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]
$passAdmin=(New-Object System.Net.WebClient).DownloadString("https://win-pw.level27.eu/rnd.php")
$passL27=(New-Object System.Net.WebClient).DownloadString("https://win-pw.level27.eu/rnd.php")

"$uid;$passAdmin;$passL27" | Out-File C:\test.txt
Write-Output $uid
