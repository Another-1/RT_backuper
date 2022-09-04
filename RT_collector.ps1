# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8082'

# учётные данные для WebUI qBittorrent.
$webui_login = 'login'
$webui_password = 'password'

$choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()

Write-Output 'Авторизуемся в клиенте'
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul

Write-Output 'Запрашиваем список раздач в разделе'
$torrents_list = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result

if ( $torrents_list.count -eq 0) {
    Write-Output 'Не получено ни одной раздачи'
    Pause
    Exit
}

Write-Output 'Ставим раздачи на закачку'
ForEach ( $id in $torrents_list.Keys ) {
    $hash = (( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_tor_hash?by=topic_id&val=' + $id ) ).content | ConvertFrom-Json -AsHashtable ).result[$id]
    $reqdata = 'urls=magnet:?xt=urn:btih:' + $hash
    Invoke-WebRequest  -Uri ( $client_url + '/api/v2/torrents/add' ) -Body $reqdata -WebSession $sid -Method Post
}
