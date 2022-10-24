New-Item -ItemType Directory -Path "$PSScriptRoot\config" -Force > $null

# Проверяем наличие файла настроек и подключаем его.
$config_path = "$PSScriptRoot\config\RT_settings.ps1"
if ( !(Test-Path $config_path) ) {
    Write-Host 'Не обнаружен файл настроек RT_settings.ps1. Создайте его в папке /config' -ForegroundColor Red
} else {
    . $config_path
}


# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

$google_folder_prefix = 'ArchRuT'
$pswd = '20RuTracker.ORG22'

# Параметры окружения (linux/windows).
$OS = @{}

# Файлы с данными, для общения между процессами
$stash_folder = @{
    default       = "$PSScriptRoot/stash"                   # Общий путь к папке
    archived      = "$PSScriptRoot/stash/archived"          # Путь к спискам архивов по дискам
    uploads_limit = "$PSScriptRoot/stash/uploads_limit.xml" # Файл записанных отдач (лимиты)
    backup_list   = "$PSScriptRoot/stash/backup_list.xml"   # Файл уже обработанного списка раздач. Для случая когда был перезапуск

    finished      = "$PSScriptRoot/stash/finished.txt"      # Файл id_hash раздач, которые были найдены в гугле или были заархивированны
    pause         = "$PSScriptRoot/stash/pause.txt"         # Если в файле что-то есть, скрипт встанет на паузу.
}

$def_paths = @{
    downloaded    = "$PSScriptRoot/config/hashes.txt"       # Файл со списком свежескачанных раздач. Добавляется из клиента
    progress      = $backuper.zip_folder + '/progress'      # Каталог хранения архивируемых раздач
    finished      = $backuper.zip_folder + '/finished'      # Каталог хранения, уже готовых к выгрузке в гугл, архивов
}

$measure_names = @{
    byte_2   = 'B','KiB','MiB','GiB','TiB','PiB'
    byte_10  = 'B','KB', 'MB', 'GB', 'TB', 'PB'
    speed_2  = 'B/s','KiB/s','MiB/s','GiB/s','TiB/s','PiB/s'
    speed_10 = 'B/s','KB/s' ,'MB/s' ,'GB/s' ,'TB/s' ,'PB/s'
}




# Получить список существующих архивов из списков по дискам.
function Get-Archives {
    # Если не используется updater, то список архивов надо обновлять принудительно.
    if ( !$used_modules.updater ) { Sync-ArchList $true }

    if ( !(Get-ChildItem $stash_folder.archived) ) {
        Write-Host 'Не обнаружено списков заархивированного. Запустите updater' -ForegroundColor Yellow
        Exit
    }

    Write-Host '[archived] Смотрим, что уже заархивировано..'
    $time_collect = [math]::Round( (Measure-Command {
        $dones = Get-Content ( $stash_folder.archived + $OS.fsep + '*.txt' )
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

# Найти ид раздач(топиков) в [списке архивов, комменте раздачи из клиента, api трекера].
# Если раздача уже есть в списке архивов, то она исключается из итогового набора раздач.
function Get-TopicIDs ( $torrents_list, $hashes ) {
    $removed = 0
    foreach ( $torrent in $torrents_list ) {
        # Если хеш есть в списке обработанных, скипаем его и отправляем в клинер.
        if ( $hashes ) {
            $topic_id = $hashes[ $torrent.hash ]
            if ( $topic_id ) {
                $removed++
                Dismount-ClientTorrent $topic_id $torrent.hash $torrent.category
                Continue
            }
        }
        # ищем коммент в данных раздачи.
        if ( !$torrent.topic_id ) {
            Get-ClientTopic $torrent
        }
        # если не удалось получить информацию об ID из коммента, сходим в API и попробуем получить там.
        if ( !$torrent.topic_id ) {
            try {
                $torrent.topic_id = ( ( Invoke-WebRequest ( 'http://api.rutracker.org/v1/get_topic_id?by=hash&val=' + $torrent.hash ) ).content | ConvertFrom-Json ).result.($torrent.hash)
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

    $torrents_list = $torrents_list | Where-Object { $nul -ne $_.topic_id }
    return $torrents_list
}

# Обновить список архивов в локальной "БД".
function Sync-ArchList ( $All = $false ) {
    $arch_folders = Get-ChildItem $google_params.folders[0] -filter "$google_folder_prefix*" -Directory

    # Собираем список гугл-дисков и проверяем наличие файла со списком архивов для каждого. Создаём если нет.
    # Проверяем даты обновления файлов и размер. Если прошло 6ч или файл пуст -> пора обновлять.
    $folders = $arch_folders | % { Watch-FileExist ($stash_folder.archived + $OS.fsep + $_.Name + '.txt') }
        | ? { $_.($OS.sizeField) -eq 0 -Or ($_.LastWriteTime -lt ( Get-Date ).AddHours( -6 )) } 
        | Sort-Object -Property LastWriteTime

    # Выбираем первый диск по условиям выше и обновляем его.
    if ( !$All ) {
        Write-Host ( '[updater] Списков требущих обновления: {0}.' -f $folders.count )
        $folders = $folders | Select -First 1
    }

    if ( !$folders ) {
        Write-Host '[updater] Нет списков для обновления. Выходим.'
        return
    }

    foreach ( $folder in $folders ) {
        $arch_path = ( $arch_folders | ? { $folder.BaseName -eq $_.BaseName } ).FullName

        Write-Host ( '[updater][{0}] Начинаем обновление списка раздач.' -f $folder.BaseName )
        $exec_time = (Measure-Command {
            $zip_list = Get-ChildItem $arch_path -Filter '*.7z' -File
            $zip_list | % { $_.BaseName } | Out-File $folder.FullName
        }).TotalSeconds

        $text = '[updater][{0}] Обновление списка раздач заняло {1} секунд. Найдено архивов: {2} шт.'
        Write-Host ( $text -f $folder.BaseName, ([math]::Round( $exec_time, 2 )), $zip_list.count )
    }
}

# Добавляем раздачу в список обработанных и возможно под удаление.
function Dismount-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category = $null ) {
    # Если отдельный модуль очистки не используется, то просто выпиливаем раздачу
    if ( !$used_modules.cleaner ) {
        Remove-ClientTorrent $torrent_id $torrent_hash $torrent_category
    }
    # Если модуль включён, то пишем в файлик.
    else {
        Watch-FileExist $stash_folder.finished > $null
        ($torrent_id.ToString() + '_' + $torrent_hash.ToLower()) | Out-File $stash_folder.finished -Append
    }
}

# Вычисляем сжатие архива, в зависимости от раздела раздачи и параметров.
function Get-Compression ( [int]$torrent_id, $params ) {
    try {
        $topic = ( Invoke-WebRequest( 'http://api.rutracker.org/v1/get_tor_topic_data?by=topic_id&val=' + $torrent_id ) ).content | ConvertFrom-Json
        $forum_id = [int]$topic.result.($torrent_id).forum_id
        $compression = $params.sections_compression[ $forum_id ]
    } catch {}
    if ( $compression -eq $null ) { $compression = $params.compression }
    if ( $compression -eq $null ) { $compression = 1 }
    return $compression
}

# По ид раздачи вычислить ид диска, название диска/папки, путь к диску
function Get-DiskParams ( [int]$torrent_id ) {
    $disk_id = [math]::Truncate(( $torrent_id - 1 ) / 300000) # 1..24
    $disk_name = $google_folder_prefix + '_' + ( 300000 * $disk_id + 1 ) + '-' + 300000 * ( $disk_id + 1 )
    $disk_path = $OS.fsep + $disk_name + $OS.fsep

    return $disk_id, $disk_name, $disk_path
}

# Вычислить номер клиента по ид диска и кол-ву акков.
function Get-GoogleNum ( [int]$DiskId, [int]$Accounts = 1, [int]$Uploaders = 1 ) {
    return @{
        account = ($DiskId % $Accounts  + 1)
        upload  = ($DiskId % $Uploaders + 1)
    }
}

# Записать размер выгруженного архива в файл и удалить старые записи.
function Get-TodayTraffic ( $uploads_all, $zip_size, $google_folder ) {
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

# Ищем файлик с данными выгрузок на диск и подгружаем его.
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

# Отобразить затраченные лимиты в разрезе периодов времени.
function Show-StoredUploads ( $uploads_all ) {
    $time_diff = 1, 3, 6, 12
    $yesterday = ( Get-date ).AddDays( -1 )
    $uploads_all.GetEnumerator() | Sort-Object Key | % {
        $disk_name = $_.key
        $full_size = ( $_.value.values | Measure-Object -sum ).Sum

        $period = [ordered]@{}
        $time_diff | % { $period[ [string]$_ ] = 0 }

        $upload = $_.value
        $actual = $upload.keys | ? { $_ -ge $yesterday }
        foreach ( $tmsp in $actual ) {
            foreach ( $h in $time_diff ) {
                if ( $tmsp -le $yesterday.addHours( $h ) ) {
                    $period[ [string]$h ] += $upload[$tmsp]
                    Break
                }
            }
        }
        Write-Host ( "[limit][{4}] Выгружено {5}. Освободится: {0}; {1}; {2}; {3}." -f @( ($period.values | % {Get-BaseSize $_}) + $disk_name + (Get-BaseSize $full_size) ) )
    }
}

# Проверка версии PowerShell.
function Confirm-Version {
    If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
        Write-Host 'У вас слишком древний PowerShell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
        Pause
        return $false
    }
    return $true
}

# Получение данных об используемой ОС.
function Get-OsParams {
    $OS.name = 'linux'
    $OS.fsep = '/'
    $OS.sizeField = 'Size'
    if ( $PSVersionTable.OS.ToLower().contains('windows')) {
        $OS.name = 'windows'
        $OS.fsep = '\'
        $OS.sizeField = 'Length'
    }
}


# Преобразовать большое число в читаемое число с множителем нужной базы.
function Get-BaseSize ( [long]$size, [int]$base = 1024, [int]$pow = 0, $SI = 'byte_2' ) {
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

# Если файла нет - создать его и вернуть свойства.
function Watch-FileExist ( $Path ) {
    If ( !(Test-Path $Path) ) {
        New-Item -ItemType File -Path $Path -Force > $null
    }
    return Get-Item $Path
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

# Вычислить размер содержимого каталога.
function Get-FolderSize ( $Path ) {
    New-Item -ItemType Directory $Path -Force > $null
    $Size = (Get-ChildItem $Path -File -Recurse | Measure-Object -Property $OS.sizeField -Sum).Sum
    if ( !$Size ) { $Size = 0 }
    return $Size
}

# Сравнить размер каталогов с максимально допустимым.
function Compare-MaxSize ( [string]$Path, [long]$MaxSize ) {
    While ( $true ) {
        $folder_size = Get-FolderSize $Path
        if ( $folder_size -le $MaxSize ) {
            break
        }

        $limit_text = '[limit][{0}] Занятый объём каталога ({1}) {2} больше допустимого {3}. Подождём пока освободится.'
        Write-Host ( $limit_text -f (Get-Date -Format t), $Path, (Get-BaseSize $folder_size), (Get-BaseSize $MaxSize) )
        Start-Sleep -Seconds 60
    }
}

# Удаление пустых каталогов по заданному пути.
function Clear-EmptyFolders ( $Path ) {
    if ( Test-Path $Path ) {
        Get-ChildItem $Path -Recurse | Where {$_.PSIsContainer -and @(Get-ChildItem -Lit $_.Fullname -r | Where {!$_.PSIsContainer}).Length -eq 0} | Remove-Item -Force
    }
}

# Test-Path с временем выполнения.
function Test-PathTimer ( $Path ) {
    $exec_time = [math]::Round( (Measure-Command {
        $result = Test-Path $Path
    }).TotalSeconds, 1 )

    return @{ result = $result; exec = $exec_time}
}

# Обеспечение работы скрипта только в заданный промежуток времени (от старт до стоп).
function Start-Stopping {
    if ( $start_time -eq $null -Or $stop_time -eq $null) { return }
    if ( $start_time -eq $stop_time ) { return }

    $now = [System.TimeOnly](Get-date -Format t)
    while ( $true) {
        # Если работаем днём  (Старт < Стоп), то пауза (Не(Старт < Сейчас < Стоп))
        # Если работаем ночью (Старт > Стоп), то пауза (Стоп < Сейчас < Старт)
        if ( $start_time -lt $stop_time ) {
            $paused = !( $start_time -le $now -and $now -le $stop_time )
        } else {
            $paused = ( $stop_time -lt $now -and $now -lt $start_time )
        }
        if ( !$paused ) { Break }

        Write-Host ( '[{0}] Пауза по расписанию, ждём начала периода ({1} - {2}).' -f $now, $start_time, $stop_time )
        Start-Sleep -Seconds 60
        $now = [System.TimeOnly](Get-date -Format t)
    }
}

# Ставим скрипт на паузу если имеется заданный файл с содержимым.
function Start-Pause {
    $pause_path = $stash_folder.pause
    while ( $true ) {
        $needSleep = $false
        $pausetime = 0

        # Если есть файлик и в нём есть содержимое - ставим скрипт на паузу.
        If ( Test-Path $pause_path) {
            $pause = ( Get-Content $pause_path | Select-Object -First 1 )
            if ( !($pause -eq $null) ) {
                $needSleep = $true
                $pausetime = $pause -as [int]
                if ( $pausetime -eq $null ) {
                    $pausetime = 5 # Дефолтное значение 5 минут.
                }
            }
        }
        if ( $needSleep ) {
            Write-Host ( '[paused] Тормозим на ' + $pausetime + ' минут.' )
            Start-Sleep -Seconds ($pausetime * 60)
        } else {
            break
        }
    }
}


# Проверка/валидация настроек.
function Sync-Settings {
    # Определяем параметры окружения.
    Get-OsParams

    $terminate = $false
    $errors = @()
    if ( !$client ) {
        $errors+= '[settings] Отсутсвует блок параметров подключения к клиенту, $client'
        $terminate = $true
    } else {
        if ( !$client.type ) {
            $errors+= '[settings] Отсутсвует тип клиента, $client.type'
            $terminate = $true
        } else {
            $client_file = "$PSScriptRoot\clients\client.{0}.ps1" -f $client.type.ToLower()
            if ( !(Test-Path $client_file) ) {
                $errors+= '[client] Выбранный торрент-клиент {0} не обнаружен или не поддерживается!' -f $client.type
                $terminate = $true
            }
        }

        if ( !$client.name -And $client.type ) {
            $client.name = $client.type
        }
    }

    if ( !$rutracker ) {
        $errors+= '[settings] Отсутсвует блок параметров подключения к форуму, $rutracker'
    }

    # Валидация настроек гугл-диска.
    if ( !$google_params ) {
        $errors+= '[settings] Отсутсвует блок параметров гугл-дисков, $google_params'
        $terminate = $true
    } else {
        # Проверяем кол-во подключённых дисков.
        if ( $google_params.accounts_count -eq $null -Or $google_params.accounts_count -gt 5 ) {
            $google_params.accounts_count = 1
        }
        # Если подключённых дисков больше одного, то кол-во акков = колву дисков
        if ( $google_params.folders.count -gt 1 ) {
            $google_params.accounts_count = $google_params.folders.count
        }
        if ( !$google_params.uploaders_count ) {
            $google_params.uploaders_count = 1
        }

        if ( $google_params.uploaders_count -gt $google_params.accounts_count ) {
            $errors+= 'Неверный набор параметров accounts_count:{0} >= uploaders_count:{1}.' -f $google_params.accounts_count, $google_params.uploaders_count
            $errors+= 'Параметры скорректированы, но проверьте файл настроек.'
            $google_params.uploaders_count = $google_params.accounts_count
        }
    }

    if ( !$backuper ) {
        $errors+= '[settings] Отсутсвует блок параметров архивирования, $backuper'
        $terminate = $true
    }

    if ( !$uploader ) {
        $errors+= '[settings] Отсутсвует блок параметров выгрузки на гугл-диск, $uploader'
    }

    if ( !$collector ) {
        $errors+= '[settings] Отсутсвует блок параметров загрузки торрент-файлов, $collector'
    }

    if ( $errors ) {
        $errors | Write-Host -ForegroundColor Yellow
    }

    # Проверим наличие заданных каталогов. (вероятно лучше перенести в проверку конфига)
    New-Item -ItemType Directory -Path $def_paths.progress -Force > $null
    New-Item -ItemType Directory -Path $def_paths.finished -Force > $null
    New-Item -ItemType Directory -Path $stash_folder.archived -Force > $null
    
    return !$terminate
}


# Подключаем файл с функциями выбранного клиента, если он есть.
if ( $client.type ) {
    $client_file = "$PSScriptRoot\clients\client.{0}.ps1" -f $client.type.ToLower()
    if ( Test-Path $client_file ) {
        Write-Host ( '[client] Выбранный торрент-клиент {0}, подключаем модуль.' -f $client.type ) -ForegroundColor Green
        . $client_file
    }
}
