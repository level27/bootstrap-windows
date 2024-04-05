$names = (get-localuser | Select-Object -expand name) -join ","
$uid=((cat C:\l27\cp4\system.ini | Select-String uid) -split('='))[1]

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$postParams = @{uid=$uid;users=$names}
Invoke-WebRequest -useb -Uri https://win-pw.level27.eu/post.php -Method POST -Body $postParams
