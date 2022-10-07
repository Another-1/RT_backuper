. "$PSScriptRoot\config\RT_settings.ps1"

# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

$google_folder_prefix = 'ArchRuT'
$pswd = '20RuTracker.ORG22'

# Файлы с данными, для общения между процессами
$stash_folder = @{
    default       = "$PSScriptRoot\stash"                   # Общий путь к папке
    archived      = "$PSScriptRoot\stash\archived"          # Путь к спискам архивов по дискам
    uploads_limit = "$PSScriptRoot\stash\uploads_limit.xml" # Файл записанных отдач (лимиты)
    backup_list   = "$PSScriptRoot\stash\backup_list.xml"   # Файл уже обработанного списка раздач. Для случая когда был перезапуск

    finished      = "$PSScriptRoot\stash\finished.txt"      # Файл id_hash раздач, которые были найдены в гугле или были заархивированны
    downloaded    = "$PSScriptRoot\config\hashes.txt"       # Файл со списком свежескачанных раздач. Добавляется из клиента
}


$pause_file = "$PSScriptRoot\stash\pause.txt"

$measure_names = @{
    byte_2   = 'B','KiB','MiB','GiB','TiB','PiB'
    byte_10  = 'B','KB', 'MB', 'GB', 'TB', 'PB'
    speed_2  = 'B/s','KiB/s','MiB/s','GiB/s','TiB/s','PiB/s'
    speed_10 = 'B/s','KB/s' ,'MB/s' ,'GB/s' ,'TB/s' ,'PB/s'
}

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
    if ( !$client -And !$client.url ) { return $false }
    return $true
}

# Если файла нет - создать его
function Watch-FileExist ( $Path ) {
    If ( !(Test-Path $Path) ) {
        New-Item -ItemType File -Path $Path -Force > $null
    }
    return Get-Item $Path
}

function Test-PathTimer ( $Path ) {
    $exec_time = [math]::Round( (Measure-Command {
        $result = Test-Path $Path
    }).TotalSeconds, 1 )

    return @{ result = $result; exec = $exec_time}
}

# Удаление пустых папок.
function Clear-EmptyFolders ( $Path ) {
    Get-ChildItem $Path -Recurse | Where {$_.PSIsContainer -and @(Get-ChildItem -Lit $_.Fullname -r | Where {!$_.PSIsContainer}).Length -eq 0} | Remove-Item -Force
}

# Получить из файла первые N строк
function Get-FileFirstContent ( [string]$Path, [int]$First = 10 ) {
    # Вытаскиваем данные из файла.
    $all_file = Get-Content $Path | Sort-Object -Unique
    # Вытаскиваем первые N строк
    $selected = $all_file | Select -First $First
    # Остальное записываем обратно
    $all_file | Select-Object -Skip $First | Out-File $Path

    return $selected
}


# Вытаскиваем список существующих архивов из списков по дискам.
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

    Write-Host ( '[archived] Обнаружено архивов: {0} [{1} сек], хешей: {2} [{3} сек]' -f $dones.count, $time_collect, $hashes.count, $time_parse )
    return $dones, $hashes
}

# По ид раздачи вычислить ид диска, название диска/папки, путь к диску
function Get-DiskParams ( [int]$torrent_id, [string]$separator = '/' ) {
    $disk_id = [math]::Truncate(( $torrent_id - 1 ) / 300000) # 1..24
    $disk_name = $google_folder_prefix + '_' + ( 300000 * $disk_id + 1 ) + '-' + 300000 * ( $disk_id + 1 )
    $disk_path = $separator + $disk_name + $separator

    return $disk_id, $disk_name, $disk_path
}

function Get-GoogleNum ( [int]$disk_id, [int]$folder_count = 1 ) {
    return ($disk_id % $folder_count + 1)
}

# Авторизация в клиенте. В случае ошибок будет прерывание, если не передан параметр.
function Initialize-Client ( $Retry = $false ) {
    $logindata = "username={0}&password={1}" -f $client.login, $client.password
    $loginheader = @{ Referer = $client.url }
    try {
        $result = Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client.url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid
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
        try {
            # Metod='torrents/info', Params='?filter=completed'
            $data = Invoke-WebRequest -uri ( $client.url + '/api/v2/' + $Metod + $Params ) -WebSession $client.sid
        }
        catch {
            Write-Host ( '[client][{0}] Не удалось получить данные методом [{1}]. Попробуем авторизоваться заново.' -f $i, $Metod )
            Start-Sleep 60
            Initialize-Client -Retry $true
        }
    }
    if ( !$data ) {
        Write-Host ( '[client] Не удалось получить данные методом [{0}], Прерываем.' -f $Metod )
        Exit
    }
    return $data.Content
}

function Get-ClientTorrents ( $Hashes ) {
    $filter = '?filter=completed'
    if ( $Hashes.Count ) {
        $filter+= '&hashes=' + ( $Hashes -Join '|' )
    }
    $torrents_list = (Read-Client 'torrents/info' $filter )
        | ConvertFrom-Json
        | Select-Object name, hash, content_path, save_path, state, size, category, priority
        | sort-object -Property size
    return $torrents_list
}

function Get-TopicIDs( $torrents_list, $hashes ) {
    $removed = 0
    foreach ( $torrent in $torrents_list ) {
        $torrent.state = $nul

        # Если хеш есть в списке обработанных, скипаем его и отправляем в клинер.
        if ( $hashes ) {
            $torrent_id = $hashes[ $torrent.hash ]
            if ( $torrent_id ) {
                $removed++
                Dismount-ClientTorrent $torrent_id $torrent.hash
                Continue
            }
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

    if ( $removed ) {
        Write-Host( '[delete] Пропущено раздач: {0}.' -f $removed )
    }
    $torrents_list = $torrents_list | Where-Object { $nul -ne $_.state }
    return $torrents_list
}

# КМК, бесполезный функционал, если тоже самое выполняет Get-TopicIDs
function Get-Required ( $torrents_list, $archives_list ) {
    $torrents_list_required = [System.Collections.ArrayList]::new()
    $torrents_list | ForEach-Object {
        $torrent_id = $_.state
        $torrent_hash = $_.hash.ToLower()
        $zip_name = $torrent_id.ToString() + '_' + $torrent_hash

        # Архива нет в списке заархивированных
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
    if ( $upload_params.cleaner ) {
        Watch-FileExist $stash_folder.finished > $null
        ($torrent_id.ToString() + '_' + $torrent_hash.ToLower()) | Out-File $stash_folder.finished -Append
    }
}

# Удаляет раздачу из клиента, если она принадлежит заданной категории и включено удаление.
function Delete-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category ) {
    if ( $upload_params.delete -eq 1 -And $upload_params.delete_category -eq $torrent_category ) {
        try {
            Write-Host ( '[delete] Удаляем из клиента раздачу {0}' -f $torrent_id )
            $reqdata = 'hashes=' + $torrent_hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST > $null
        }
        catch {
            Write-Host ( '[delete] Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
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
    New-Item -ItemType Directory -Path $folder_path -Force > $null
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
function Get-FileSize ( [long]$size, [int]$base = 1024, [int]$pow = 0, $SI = 'byte_2' ) {
    $names = $measure_names[$SI]
    if ( !$names ) { $names = $measure_names.byte_2 }

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
