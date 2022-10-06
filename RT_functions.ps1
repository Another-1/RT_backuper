. "$PSScriptRoot\config\RT_settings.ps1"

$pswd = '20RuTracker.ORG22'

# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

$google_folder_prefix = 'ArchRuT'

$stash_folder = @{
    default       = "$PSScriptRoot\stash"                   # Общий путь к папке
    archived      = "$PSScriptRoot\stash\archived"          # Путь к спискам архивов по дискам
    uploads_limit = "$PSScriptRoot\stash\uploads_limit.xml" # Файл записанных отдач (лимиты)
    backup_list   = "$PSScriptRoot\stash\backup_list.xml"   # Файл уже обработанного списка раздач. Для случая когда был перезапуск
}

# Файлы с данными, для общения между процессами
$dones_log_file  = "$PSScriptRoot\stash\uploaded_files.txt"
$remove_log_file = "$PSScriptRoot\stash\remove_files.txt"

$pause_file = "$PSScriptRoot\stash\pause.txt"

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
    $folder_separator = '/'
    if ( $PSVersionTable.OS.ToLower().contains('windows')) {
        $os = 'windows'
        $folder_separator = ':\' 
    }
    return $os, $folder_separator
}

function Sync-Settings {
    if ($nul -eq $client_url ) { return $false }
    else { return $true }
}

# Если файла нет - создать его
function Watch-FileExist ( $FilePath ) {
    If ( !(Test-Path $FilePath) ) {
        New-Item -ItemType File -Path $FilePath -Force | Out-Null
    }
    return Get-Item $FilePath
}

# Удаление пустых папок.
function Clear-EmptyFolders ( $FilePath ) {
    Get-ChildItem $FilePath -Recurse | Where {$_.PSIsContainer -and @(Get-ChildItem -Lit $_.Fullname -r | Where {!$_.PSIsContainer}).Length -eq 0} | Remove-Item -Force
}

function Get-Archives {
    Write-Host '[archived] Смотрим, что уже заархивировано..'
    $time_collect = [math]::Round( (Measure-Command {
        $dones = Get-Content ( $stash_folder.archived + '\*.txt' )
    }).TotalSeconds, 1 )

    $time_parse = [math]::Round( (Measure-Command {
        $hashes = @{}
        $dones | % {
            $id, $hash = $_.Split('_')
            if ( $id -And $hash ) {
                $hashes[$hash] = $id
            }
        }
    }).TotalSeconds, 1 )

    Write-Host ( '[archived] обнаружено архивов: {0} [{1} сек], хешей: {2} [{3} сек]' -f $dones.count, $time_collect, $hashes.count, $time_parse )
    return $dones, $hashes
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
        $all_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?filter=completed' ) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | sort-object -Property size
        $torrents_list = $all_torrents_list | Where-Object { $_.state -eq 'uploading' -or $_.state -eq 'pausedUP' -or $_.state -eq 'queuedUP' -or $_.state -eq 'stalledUP' }
        return $torrents_list
    }
    else {
        $reqdata = 'hashes=' + ( $t_args -Join '|' )
        $torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?filter=completed&' + $reqdata) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | Where-Object { $_.state -ne 'downloading' -and $_.state -ne 'stalledDL' -and $_.state -ne 'queuedDL' -and $_.state -ne 'error' -and $_.state -ne 'missingFiles' } | sort-object -Property size
        return $torrents_list
    }
}

function Get-TopicIDs( $torrents_list, $hashes ) {
    foreach ( $torrent in $torrents_list ) {
        $torrent.state = $nul

        # ищем ид раздачи в списке уже обработанных.
        if ( $hashes ) {
            $torrent.state = $hashes[ $torrent.hash ]
        }
        # ищем коммент в данных раздачи.
        if ( $nul -eq $torrent.state ) {
            try {
                $reqdata = 'hash=' + $torrent.hash
                $torprops = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/properties' ) -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json
                if ( $torprops.comment -match 'rutracker' ) {
                    $torrent.state = ( Select-String "\d*$" -InputObject $torprops.comment).Matches.Value
                }
            } catch { pause }
        }
        # если не удалось получить информацию об ID из коммента, сходим в API и попробуем получить там.
        if ( $nul -eq $torrent.state ) {
            try {
                $torrent.state = ( ( Invoke-WebRequest ( 'http://api.rutracker.org/v1/get_topic_id?by=hash&val=' + $torrent.hash ) ).content | ConvertFrom-Json ).result.($torrent.hash)
            } catch {
                Write-Host ('[RT_API] Не удалось получить номер топика, hash={0}' -f $torrent.hash )
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

function Get-Required ( $torrents_list, $archives_list ) {
    $torrents_list_required = [System.Collections.ArrayList]::new()
    $torrents_list | ForEach-Object {
        $torrent_id = $_.state
        $torrent_hash = $_.hash.ToLower()
        $zip_name = $torrent_id.ToString() + '_' + $torrent_hash

        # Архиав нет в списке заархивированных
        if ( $zip_name -notin $archives_list ) {
            if ( $torrent_id -ne '' ) {
                $torrents_list_required += $_
            }
        }
        # Есть в списке - пробуем удалить
        else {
            Dismount-ClientTorrent $torrent_id $torrent_hash
        }

    }

    return $torrents_list_required
}

# Добавляем архив в список обработанных и список для проверки на удаление
function Dismount-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash ) {
    Watch-FileExist $remove_log_file | Out-Null

    $zip_name = $torrent_id.ToString() + '_' + $torrent_hash.ToLower()
    $zip_name | Out-File $remove_log_file -Append
    $zip_name | Out-File $dones_log_file  -Append
}

# Удаляет раздачу из клиента, если она принадлежит заданной категории и включено удаление.
function Delete-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category ) {
    if ( $delete_processed -eq 1 -And $default_category -eq $torrent_category ) {
        try {
            Write-Host ( 'Удаляем из клиента раздачу {0}' -f $torrent_id )
            $reqdata = 'hashes=' + $torrent_hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST | Out-Null
        }
        catch {
            Write-Host ( 'Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
        }
    }
}

# Вычисляем сжатие архива, в зависимости от раздела раздачи и параметров.
function Get-Compression ( $torrent_id, $params ) {
    try {
        $topic = ( Invoke-WebRequest( 'http://api.rutracker.org/v1/get_tor_topic_data?by=topic_id&val=' + $torrent_id )).content | ConvertFrom-Json
        $forum_id = [int]$topic.result.($torrent_id).forum_id
        $compression = $params.sections_compression[ $forum_id ]
    } catch {}
    if ( $compression -eq $null ) { $compression = $params.compression }
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
    $uploads_all | Export-Clixml -Path $stash_folder.uploads_limit
    return ( $uploads.values | Measure-Object -sum ).Sum, $uploads_all
}

# Ищем файлик с данными выгрузок на диск и подгружаем его
function Get-StoredUploads ( $uploads_old = @{} ) {
    $uploads_all = @{}
    If ( Test-Path $stash_folder.uploads_limit ) {
        try {
            $uploads_all = Import-Clixml -Path $stash_folder.uploads_limit
        } catch {
            $uploads_all = $uploads_old
        }
    }
    return $uploads_all
}

# Вычислить размер содержимого папки
function Get-FolderSize ( [string]$folder_path ) {
    New-Item -ItemType Directory -Path $folder_path -Force | Out-Null
    return (Get-ChildItem $folder_path -Recurse | Measure-Object -Property Length -Sum).Sum
}

function Compare-MaxFolderSize ( [long]$folder_size, [long]$folder_size_max ) {
    if ( $folder_size -gt $folder_size_max ) {
        return $true
    }
    return $false
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
    while ( $true ) {
        $needSleep = $false
        $pausetime = 0

        # Если есть файлик и в нём есть содержимое - ставим скрипт на паузу.
        If ( Test-Path $pause_file) {
            $pause = ( Get-Content $pause_file | Select-Object -First 1 )
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
