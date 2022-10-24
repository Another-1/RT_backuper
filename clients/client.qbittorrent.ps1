###################################################################################################
#################################  ФУНКЦИИ СВЯЗАННЫЕ С КЛИЕНТОМ  ##################################
###################################################################################################
#https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)

# Авторизация в клиенте. В случае ошибок будет прерывание, если не передан параметр.
function Initialize-Client ( $Retry = $false ) {
    $logindata = "username={0}&password={1}" -f $client.login, $client.password
    $loginheader = @{ Referer = $client.url }
    try {
        Write-Host '[client] Авторизуемся в клиенте.'
        $url = $client.url + '/api/v2/auth/login'
        $result = Invoke-WebRequest -Method POST -Uri $url -Headers $loginheader -Body $logindata -SessionVariable sid
        if ( $result.StatusCode -ne 200 ) {
            throw 'You are banned.'
        }
        if ( $result.Content -ne 'Ok.') {
            throw $result.Content
        }
        $client.sid = $sid
    }
    catch {
        if ( !$Retry ) {
            Write-Host ( '[client] Не удалось авторизоваться в клиенте, прерываем. Ошибка: {0}.' -f $Error[0] ) -ForegroundColor Red
            Exit
        }
    }
}

# Получить данные от клиента по заданному методу и параметрам.
function Read-Client ( [string]$Metod, $Params ) {
    for ( $i = 1; $i -lt 5; $i++ ) {
        $url = $client.url + '/api/v2/' + $Metod
        try {
            $data = Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Body $Params
            Break
        }
        catch {
            Write-Host ( '[client][{0}] Не удалось получить данные методом [{1}]. Попробуем авторизоваться заново.' -f $i, $Metod )
            Start-Sleep 60
            Initialize-Client -Retry $true
        }
    }
    return $data.Content
}

# Получаем данные о клиенте.
function Get-ClientVerion {
    $version_info = @()
    $version_info += "- verion: {0}" -f (Read-Client 'app/version')
    $version_info += "- apiVersion: {0}" -f (Read-Client 'app/webapiVersion')
    $version_info += "- build: {0}" -f (Read-Client 'app/buildInfo')

    return $version_info
}

# Обязательный список полей:
# name, hash, topic_id, comment, status, content_path, save_path, state, size, category
# Получить список завершённых раздач.
function Get-ClientTorrents ( $Hashes, $Completed = $true, $Sort = 'size' ) {
    $Params = @{}
    if ( $Completed ) {
        $Params.filter = 'completed'
    }
    if ( $Hashes.count ) {
        $Params.hashes = $Hashes -Join '|'
    }
    $torrents_list = (Read-Client 'torrents/info' $Params )
        | ConvertFrom-Json
        | Select-Object name, hash, content_path, save_path, state, size, category,
            @{N='topic_id'; E={$null}},
            @{N='comment';  E={$null}},
            @{N='status';   E={$_.state}}
        | Sort-Object -Property $Sort

    return $torrents_list
}

# Получить ид раздачи из данных торрента.
function Get-ClientTopic ( $torrent ) {
    $filter = @{hash = $torrent.hash }
    if ( !$torrent.topic_id ) {
        $torprops = (Read-Client 'torrents/properties' $filter ) | ConvertFrom-Json
        if ( $torprops.comment -match 'rutracker' ) {
            $torrent.topic_id = ( Select-String "\d*$" -InputObject $torprops.comment ).Matches.Value
        }
    }
}

# Добавить заданный торрент файл в клиент
function Add-ClientTorrent ( $Hash, $File, $Path, $Category ) {
    $Params = @{
        torrents    = Get-Item $File
        savepath    = $Path
        category    = $Category
        name        = 'torrents'
        root_folder = 'false'
    }

    $url = $client.url + '/api/v2/torrents/add'
    Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' > $null
}

# Удаляет раздачу из клиента, если она принадлежит заданной категории и включено удаление.
function Remove-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category ) {
    if ( $uploader.delete -eq 1 -And $uploader.delete_category -eq $torrent_category ) {
        try {
            Write-Host ( '[delete] Удаляем из клиента раздачу {0}' -f $torrent_id )
            $request_delete = @{
                hashes = $torrent_hash
                deleteFiles = $true
            }
            Read-Client 'torrents/delete' $request_delete > $null
        }
        catch {
            Write-Host ( '[delete] Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
        }
    }
}
###################################################################################################
