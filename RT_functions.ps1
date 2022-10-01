. "$PSScriptRoot\config\RT_settings.ps1"


$upload_log_file = "$PSScriptRoot\stash\uploads_all.xml"
$dones_log_file = "$PSScriptRoot\stash\uploaded_files.xml"

# Проверка версии PowerShell
function Confirm-Version {
    If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
        Write-Host 'У вас слишком древний PowerShell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
        Pause
        return $false
    }
    return $true
}

function Get-OsParams {
    $os = 'linux'
    $drive_separator = '/'
    if ( $PSVersionTable.OS.ToLower().contains('windows')) {
        $os = 'windows'
        $drive_separator = ':\' 
    }
    return $os, $drive_separator
}

function Sync-Settings {
    if ($nul -eq $client_url ) { return $false }
    else { return $true }
}

# Если файла нет - создать его
function Watch-FileExist ( $FilePath ) {
    If ( !(Test-Path -path $FilePath) ) {
        New-Item -ItemType File -Path $FilePath -Force | Out-Null
    }
    return Get-Item $FilePath
}

function Get-Archives ( $google_folders ) {
    Write-Host 'Смотрим, что уже заархивировано..'
    $file = Watch-FileExist $dones_log_file
    # Если файл пуст, или его обновление было более 24х назад - обновляем заново
    try {
        $dones = Import-Clixml -Path $dones_log_file
    } catch {
        $update = $true
    }
    if ( $file.size -eq 0 -Or $file.LastWriteTime -lt ( Get-Date ).AddHours(-24) ) {
        $update = $true
    }
    # $update = $true
    if ( $update ) {
        $dones = @{}
        Get-ChildItem -Recurse $google_folders[0] | Where { ! $_.PSIsContainer } | ForEach-Object { $dones[$_.BaseName.ToLower()] = 1 }
        $dones| Export-Clixml -Path $dones_log_file
        Write-Host ( 'Список архивов обновлён, найдено {0} файлов.' -f $dones.count )
    }
    return $dones
}

# По ид раздачи вычислить ид диска, название диска/папки, путь к диску
function Get-DiskParams ( [int]$torrent_id, [string]$separator = '/' ) {
    $disk_id = [math]::Truncate(( $torrent_id - 1 ) / 300000) # 1..24
    $disk_name = 'ArchRuT_' + ( 300000 * $disk_id + 1 ) + '-' + 300000 * ( $disk_id + 1 )
    $disk_path = $separator + $disk_name + $separator

    return $disk_id, $disk_name, $disk_path
}

function Get-GoogleNum ( [int]$disk_id, [int]$folder_count = 1 ) {
    return ($disk_id % $folder_count + 1)
}

function Initialize-Client {
    $logindata = "username=$webui_login&password=$webui_password"
    $loginheader = @{ Referer = $client_url }
    Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul
    return $sid
}

function Get-ClientTorrents ($client_url, $sid, $t_args) {
    if ( $t_args.Count -eq 0 ) {
        $all_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' ) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | sort-object -Property size
        $torrents_list = $all_torrents_list | Where-Object { $_.state -eq 'uploading' -or $_.state -eq 'pausedUP' -or $_.state -eq 'queuedUP' -or $_.state -eq 'stalledUP' }
        return $torrents_list
    }
    else {
        $reqdata = 'hashes=' + $t_args[0]
        $torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?' + $reqdata) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | Where-Object { $_.state -ne 'downloading' -and $_.state -ne 'stalledDL' -and $_.state -ne 'queuedDL' -and $_.state -ne 'error' -and $_.state -ne 'missingFiles' } | sort-object -Property size
        return $torrents_list
    }
}

function Get-TopicIDs( $torrents_list ) {
    foreach ( $torrent in $torrents_list ) {
        $torrent.state = $nul
        # ищем коммент в данных раздачи
        try {
            $reqdata = 'hash=' + $torrent.hash
            $torprops = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/properties' ) -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json
            if ( $torprops.comment -match 'rutracker' ) {
                $torrent.state = ( Select-String "\d*$" -InputObject $torprops.comment).Matches.Value
            }
        } catch { pause }
        # если не удалось получить информацию об ID из коммента, сходим в API и попробуем получить там
        if ( $nul -eq $torrent.state ) {
            try {
                $torrent.state = ( ( Invoke-WebRequest ( 'http://api.rutracker.org/v1/get_topic_id?by=hash&val=' + $torrent.hash ) ).content | ConvertFrom-Json ).result.($torrent.hash)
            } catch {
                Write-Host ('Не удалось получить номер топика, hash={0}' -f $torrent.hash )
            }
        }
        # исправление путей для кривых раздач с одним файлом в папке
        if ( ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '')) -match ('[\\/]') ) {
            $separator = $matches[0]
            $torrent.content_path = $torrent.save_path + $separator + ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '') -replace ('[\\/].*$', '') )
        }
    }
    $torrents_list = $torrents_list | Where-Object { $nul -ne $_.state }
    return $torrents_list
}

function Get-Required ( $torrents_list, $dones ) {
    $torrents_list_required = [System.Collections.ArrayList]::new()
    $deleted = 0
    $torrents_list | ForEach-Object {
        $torrent_id = $_.state.ToString()
        $torrent_hash = $_.hash.ToLower()
        if ( $torrent_id -ne '' -and ( $torrent_id + '_' + $torrent_hash ) -notin $dones.keys ) {
            $torrents_list_required += $_
        }
        elseif ( $delete_processed -eq 1 -And $_.category -eq $default_category ) {
            $reqdata = 'hashes=' + $torrent_hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST > $nul
            $deleted++
        }
    }
    if ( $deleted -gt 0 ) {
        Write-Host ( 'Из клиента удалено {0} раздач.' -f $deleted )
    }
    return $torrents_list_required
}

function Get-Compression ( $torrent_id ) {
    try {
        $topic = ( Invoke-WebRequest( 'http://api.rutracker.org/v1/get_tor_topic_data?by=topic_id&val=' + $torrent_id )).content | ConvertFrom-Json
        $forum_id = [int]$topic.result.($torrent_id).forum_id
        $compression = $sections_compression[ $forum_id ]
    } catch {}
    if ( $compression -eq $null ) { $compression = $default_compression }
    if ( $compression -eq $null ) { $compression = 1 }
    return $compression
}

function Get-TodayTraffic ( $uploads_all, $zip_size, $google_folder) {
    $uploads_all = Get-StoredUploads $uploads_all
    $now = Get-date
    $daybefore = $now.AddDays( -1 )
    $uploads_tmp = @{}
    $uploads = $uploads_all[ $google_folder ]
    $uploads.keys | Where-Object { $_ -ge $daybefore } | ForEach-Object { $uploads_tmp += @{ $_ = $uploads[$_] } }
    $uploads = $uploads_tmp
    if ($zip_size -gt 0) {
        $uploads += @{ $now = $zip_size }
    }
    $uploads_all[$google_folder] = $uploads
    $uploads_all | Export-Clixml -Path $upload_log_file
    return ( $uploads.values | Measure-Object -sum ).Sum, $uploads_all
}

# Ищем файлик с данными выгрузок на диск и подгружаем его
function Get-StoredUploads ( $uploads_old = @{} ) {
    $uploads_all = @{}
    If ( Test-Path -path $upload_log_file ) {
        try {
            $uploads_all = Import-Clixml -Path $upload_log_file
        } catch {
            $uploads_all = $uploads_old
        }
    }
    return $uploads_all
}

# Запуск бекапа только в заданный промежуток времени (от старт до стоп)
function Start-Stopping {
    if ( $start_time -eq $null -Or $stop_time -eq $null) { return }
    if ( $start_time -gt $stop_time ) { return }

    $now = Get-date -Format t
    $paused = $false
    # Старт < Сейчас < Стоп
    while ( !($start_time -lt $now -and $now -lt $stop_time) ) {
        $now = Get-date -Format t
        Write-Host $now
        if ( -not $paused ) {
            Write-Host "Останавливаемся по расписанию, ждём до $start_time"
            $paused = $true
        }
        Start-Sleep -Seconds 60
    }
}

# Ставим скрипт на паузу если имеется заданный файл с содержимым.
function Start-Pause {
    $pausefile = "$PSScriptRoot\config\pause.txt"

    while ( $true ) {
        $needSleep = $false
        $pausetime = 0

        # Если есть файлик и в нём есть содержимое - ставим скрипт на паузу.
        If ( Test-Path -path $pausefile) {
            $pause = ( Get-Content $pausefile | Select-Object -First 1 )
            if ( !($pause -eq $null) ) {
                $needSleep = $true
                $pausetime = $pause -as [int]
                if ( $pausetime -eq $null ) {
                    $pausetime = 5 # Дефолтное значение 5 минут.
                }
            }
        }
        if ( $needSleep ) {
            Write-Host ( 'Обнаружен вызов паузы, тормозим на ' + $pausetime + ' минут.' )
            Start-Sleep -Seconds ($pausetime * 60)
        } else {
            break
        }
    }
}

# Преобразовать размер файла в байтах, до ближайшего целого меньше базы
function Get-FileSize ( [long]$size, [int]$base = 1024, [int]$pow = 0 ) {
    $names = 'B','KiB','MiB','GiB','TiB','PiB'
    if ( $base -ne 1024 ) {
        $names = ''
    }

    $val = 0
    if ( $size -gt 0 ) {
        if ( $pow -le 0 ) {
            $pow = [math]::Floor( [math]::Log( $size, $base) )
        }
        if ( $pow -gt $names.count - 1 ) {
            $pow = $names.count - 1
        }
        $val = [math]::Round( $size / [math]::Pow($base, $pow), 1)
    }

    return ( $val ).ToString() + ' ' + $names[ $pow ]
}
