# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8082'

# учётные данные для WebUI qBittorrent.
$webui_login = 'login'
$webui_password = 'password'

# тут указываем каталог общих папок Google Drive.
$google_folder = 'M:\Shared drives'

##### Дальше начинается собственно код, там в идеале ничего менять не нужно.

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
    $reqdata = @{'by' = 'topic_id'; 'val' = $id.ToString() }
    $status = (( Invoke-WebRequest -uri 'http://api.rutracker.org/v1/get_tor_topic_data' -body $reqdata).content | ConvertFrom-Json -AsHashtable ).result[$id].tor_status
    # поглощённые раздачи пропускаем
    if ( -not ( $status -eq 7 ) ) {
        $hash = (( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_tor_hash?by=topic_id&val=' + $id ) ).content | ConvertFrom-Json -AsHashtable ).result[$id]
        $folder_name = '\ArchRuT_' + ( 300000 * [math]::Truncate(( $id - 1 ) / 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $id - 1 ) / 300000) + 1 ) + '\'
        $zip_name = $google_folder + $folder_name + $id + '_' + $hash.ToLower() + '.7z'
        if ( -not ( test-path -Path $zip_name ) ) { # закачиваем только если ещё нет на гугле
            $reqdata = 'urls=magnet:?xt=urn:btih:' + $hash
            Invoke-WebRequest  -Uri ( $client_url + '/api/v2/torrents/add' ) -Body $reqdata -WebSession $sid -Method Post > $nul
            Start-Sleep -Seconds 2
            $reqdata = 'hash=' + $hash + '&urls=http%3A%2F%2Fbt.t-ru.org%2Fann%3Fmagnet'
            Invoke-WebRequest  -Uri ( $client_url + '/api/v2/torrents/addTrackers' ) -Body $reqdata -WebSession $sid -Method Post > $nul
        }
    }
}
