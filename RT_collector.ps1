. "$PSScriptRoot\RT_settings.ps1"

if ($client_url -eq '' -or $nul -eq $client_url ) {
    Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'
    Pause
    exit
}

$choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()

Write-Output 'Авторизуемся в клиенте'
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul
Write-Output 'Получаем список завершённых раздач из клиента'
$client_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' )-WebSession $sid ).Content | ConvertFrom-Json | Select-Object hash


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
    $hash = (( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_tor_hash?by=topic_id&val=' + $id ) ).content | ConvertFrom-Json -AsHashtable ).result[$id]
    if ( $client_torrents_list -notcontains $hash ) {
        $folder_name = '\ArchRuT_' + ( 300000 * [math]::Truncate(( $id - 1 ) / 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $id - 1 ) / 300000) + 1 ) + '\'
        $zip_name = $google_folder + $folder_name + $id + '_' + $hash.ToLower() + '.7z'
        # закачиваем только если ещё нет на гугле
        if ( -not ( test-path -Path $zip_name ) ) {
            # поглощённые раздачи пропускаем
            $status = (( Invoke-WebRequest -uri 'http://api.rutracker.org/v1/get_tor_topic_data' -body $reqdata).content | ConvertFrom-Json -AsHashtable ).result[$id].tor_status
            if ( -not ( $status -eq 7 ) ) {
                $reqdata = 'urls=magnet:?xt=urn:btih:' + $hash
                Invoke-WebRequest  -Uri ( $client_url + '/api/v2/torrents/add' ) -Body $reqdata -WebSession $sid -Method Post > $nul
                Start-Sleep -Seconds 2
                $reqdata = 'hash=' + $hash + '&urls=http%3A%2F%2Fbt.t-ru.org%2Fann%3Fmagnet'
                Invoke-WebRequest  -Uri ( $client_url + '/api/v2/torrents/addTrackers' ) -Body $reqdata -WebSession $sid -Method Post > $nul
            }
        }
    }
}
 
