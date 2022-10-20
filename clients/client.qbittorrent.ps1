
###################################################################################################
#################################  ФУНКЦИИ СВЯЗАННЫЕ С КЛИЕНТОМ  ##################################
###################################################################################################
# Авторизация в клиенте. В случае ошибок будет прерывание, если не передан параметр.
function Initialize-Client ( $Retry = $false ) {
    $logindata = "username={0}&password={1}" -f $client.login, $client.password
    $loginheader = @{ Referer = $client.url }
    try {
        Write-Host '[client] Авторизуемся в клиенте.'
        $result = Invoke-WebRequest -Headers $loginheader -Uri ( $client.url + '/api/v2/auth/login' ) -Body $logindata -Method POST -SessionVariable sid
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

# Получить данные от клиента по заданному методу и параметрам. Параметры должны начинаться с ?
function Read-Client ( [string]$Metod, [string]$Params = '' ) {
    for ( $i = 1; $i -lt 5; $i++ ) {
        $url = $client.url + '/api/v2/' + $Metod + $Params
        try {
            # Metod='torrents/info', Params='?filter=completed'
            $data = Invoke-WebRequest -Uri $url -WebSession $client.sid
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

# Получить список завершённых раздач. Опционально, по списку хешей.
function Get-ClientTorrents ( $Hashes ) {
    $filter = '?filter=completed'
    if ( $Hashes.count ) {
        $filter += '&hashes=' + ( $Hashes -Join '|' )
    }
    $torrents_list = (Read-Client 'torrents/info' $filter )
        | ConvertFrom-Json
        | Select-Object name, hash, content_path, save_path, state, size, category
        | Sort-Object -Property size
    return $torrents_list
}

# Удаляет раздачу из клиента, если она принадлежит заданной категории и включено удаление.
function Remove-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category ) {
    if ( $uploader.delete -eq 1 -And $uploader.delete_category -eq $torrent_category ) {
        try {
            Write-Host ( '[delete] Удаляем из клиента раздачу {0}' -f $torrent_id )
            $request = '?hashes=' + $torrent_hash + '&deleteFiles=true'
            Read-Client 'torrents/delete' $request > $null
        }
        catch {
            Write-Host ( '[delete] Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
        }
    }
}
###################################################################################################
