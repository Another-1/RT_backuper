###################################################################################################
#################################  ФУНКЦИИ СВЯЗАННЫЕ С КЛИЕНТОМ  ##################################
###################################################################################################
# https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md

# Авторизация в клиенте. В случае ошибок будет прерывание, если не передан параметр.
function Initialize-Client ( $Retry = $false ) {
    # Кодируем логин:пароль
    if ( !$client.cred ) {
        $pair = "{0}:{1}" -f $client.login, $client.password
        $client.cred = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    }

    $client.headers = @{
        Authorization = ( "Basic {0}" -f $client.cred )
    }
    $body = @{
        method = 'session-get'
        arguments = @{
            fields = @( 'version' )
        }
    }

    $url = $client.url + '/transmission/rpc'
    # Авторизуемся в клиенте, получаем сид, записываем в заголовок.
    try {
        $result = Invoke-WebRequest -Method POST -Uri $url -Headers $client.headers -Body ( $body | ConvertTo-Json )
    } catch {
        $match = Select-String 'X-Transmission-Session-Id: (.*)' -InputObject $Error[0]
        $sid = $match.Matches.Groups[1].Value
        if ( $sid ) {
            $client.sid = $sid
            $client.headers['X-Transmission-Session-Id'] = $sid
        }
    }
    try {
        $result = Invoke-WebRequest -Method POST -Uri $url -Headers $client.headers -Body ( $body | ConvertTo-Json )
        if ( $result.Content ) {
            $version = ( $result.Content | ConvertFrom-Json ).arguments.version
        }
    } catch {
        if ( !$Retry ) {
            Write-Host ( '[client] Не удалось авторизоваться в клиенте, прерываем. Ошибка: {0}.' -f $Error[0] ) -ForegroundColor Red
            Exit
        }
    }
}

# Получить данные от клиента по заданному методу и параметрам.
function Read-Client ( $Params ) {
    for ( $i = 1; $i -lt 5; $i++ ) {
        $url = $client.url + '/transmission/rpc'
        try {
            $data = Invoke-WebRequest -Method POST -Uri $url -Headers $client.headers -Body ( $Params | ConvertTo-Json )
            Break
        }
        catch {
            Write-Host ( '[client][{0}] Не удалось получить данные методом [{1}]. Попробуем авторизоваться заново.' -f $i, $Params.method )
            Start-Sleep 60
            Initialize-Client -Retry $true
        }
    }
    return $data.Content
}

# Получаем данные о клиенте.
function Get-ClientVerion {
    $Params = @{
        method = 'session-get'
        arguments = @{
            fields = @(
                'version'
                'rpc-version'
            )
        }
    }

    $version_info = @()
    (Read-Client $Params | ConvertFrom-Json -AsHashTable).arguments.GetEnumerator() | % {
        $version_info += '- {0}: {1}' -f $_.key, $_.value
    }

    return $version_info
}

# Обязательный список полей:
# name, hash, topic_id, comment, status, content_path, save_path, state, size, category
# Получить список завершённых раздач.
function Get-ClientTorrents ( $Hashes, $Completed = $true, $Sort = 'size' ) {
    $Params = @{
        method = 'torrent-get'
        arguments = @{
            fields = @(
                'name'
                'status'
                'hashString'
                'comment'
                'totalSize'
                'downloadDir'
                'percentDone'
                'labels'
            )
        }
    }

    if ( $Hashes.count ) {
        $Params.arguments.ids = $Hashes
    }
    $torrents_list = (Read-Client $Params | ConvertFrom-Json).arguments.torrents
    if ( $Completed ) {
        $torrents_list = $torrents_list | ? { $_.percentDone -eq 1 }
    }
    $torrents_list = $torrents_list | Select-Object name, status, comment,
            @{N='topic_id';  E={$null}},
            @{N='hash';      E={$_.hashString}},
            @{N='size';      E={$_.totalSize}},
            @{N='category';  E={$_.labels -Join ''}},
            @{N='save_path'; E={$_.downloadDir}},
            @{N='content_path'; E={$_.downloadDir + $OS.fsep + $_.name}}
        | Sort-Object -Property $Sort

    return $torrents_list
}

# Получить ид раздачи из данных торрента.
function Get-ClientTopic ( $torrent) {
    if ( !$torrent.topic_id ) {
        if ( $torrent.comment -match 'rutracker' ) {
            $torrent.topic_id = ( Select-String "\d*$" -InputObject $torrent.comment ).Matches.Value
        }
    }
}

# Добавить заданный торрент файл в клиент
function Add-ClientTorrent ( $Hash, $File, $Path, $Category ) {
    $base64 = [convert]::ToBase64String(( Get-Content $File -AsByteStream -Raw ))
    $Params = @{
        method = 'torrent-add'
        arguments = @{
            'download-dir' = $Path
            'metainfo' = $base64
            'paused' = $false
        }
    }

    # Добавляем раздачу в клиент.
    $added = Read-Client $Params

    # Если есть категория, присваиваем её (в torrent-add оно не рботает, почему то).
    if ( $Category ) {
        $set_category = @{
            method = 'torrent-set'
            arguments = @{
                'ids' = @( $Hash )
                'labels' = @( $Category )
            }
        }
        Read-Client $set_category > $null
    }

    return $added
}


# Удаляет раздачу из клиента, если она принадлежит заданной категории и включено удаление.
function Remove-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category ) {
    if ( $uploader.delete -eq 1 -And $uploader.delete_category -eq $torrent_category ) {
        try {
            Write-Host ( '[delete] Удаляем из клиента раздачу {0}' -f $torrent_id )
            $request_delete = @{
                method = 'torrent-remove'
                arguments = @{
                    'ids' = @( $torrent_hash )
                    'delete-local-data' = $true
                }
            }
            Read-Client $request_delete > $null
        }
        catch {
            Write-Host ( '[delete] Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
        }
    }
}
###################################################################################################
