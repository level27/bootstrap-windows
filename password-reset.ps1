$uid=((cat C:\l27\cp4\system.ini | sls uid) -split('='))[1];$uid
$passAdmin=(iwr https://win-pw.level27.eu/rnd.php).content
$passL27=(iwr https://win-pw.level27.eu/rnd.php).content

Write-Output $passL27
