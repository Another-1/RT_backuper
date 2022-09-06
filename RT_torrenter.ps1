. "$PSScriptRoot\RT_settings.ps1"

if ($client_url -eq '' -or $nul -eq $client_url ) {
    Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'
    Pause
    exit
}

$ids = @(
    6250068
    3463348
)

Write-Output 'Авторизуемся на форуме'
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker_login; 'login_password' = $rutracker_password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds | Out-Null

Write-Output 'Качаем торренты'
if ( $PSVersionTable.OS.ToLower().contains('windows')) {
    $separator = '\'
}
else {
    $separator = '/'
}

foreach ($id in $ids) {
    Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile ( $temp_folder + $separator + "$id.torrent") | Out-Null
}