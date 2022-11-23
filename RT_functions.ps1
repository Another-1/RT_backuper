function Write-Verbose ( [string]$Text ){
    if ( $Verbose ) { Write-Host ( '[{0:t}] {1}' -f (Get-Date), $Text ) }
}

$RT_version = 'v2.1.5-dev'
Write-Verbose "RT_versios: $RT_version"

New-Item -ItemType Directory -Path "$PSScriptRoot\config" -Force > $null

# Проверяем наличие файла настроек и подключаем его.
$config_path = "$PSScriptRoot\config\RT_settings.ps1"
if ( !(Test-Path $config_path) ) {
    Write-Host 'Не обнаружен файл настроек RT_settings.ps1. Создайте его в папке /config' -ForegroundColor Red
} else {
    . $config_path
}
Write-Verbose 'Config connected'

# Если задано несколько клиентов, пробуем определить нужный.
if ( $client_list.count ) {
    if ( !$client -And $UsedClient ) {
        $client = $client_list | ? { $_.name -eq $UsedClient }
    }
    if ( !$client ) { $client = $client_list[0] }
    $client_list | % { $_.name } | Out-File "$PSScriptRoot/clients.txt"
}
Write-Verbose 'Clients counted'

# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

$google_folder_prefix = 'ArchRuT'
$pswd = '20RuTracker.ORG22'

# Параметры окружения (linux/windows).
$OS = @{}


$def_paths = [ordered]@{
    progress      = $backuper.zip_folder + '/progress'           # Каталог хранения архивируемых раздач
    finished      = $backuper.zip_folder + '/finished'           # Каталог хранения, уже готовых к выгрузке в гугл, архивов

    downloaded    = "$PSScriptRoot/stash/{0}/hashes.txt"         # Файл со списком свежескачанных раздач. Добавляется из клиента
    backup_list   = "$PSScriptRoot/stash/{0}/backup_list.xml"    # Файл уже обработанного списка раздач. Для случая когда был перезапуск
    finished_list = "$PSScriptRoot/stash/{0}/finished_list.txt"  # Файл id_hash обработанных раздач, которые надо уделать, если это необходимо
}

# Временные файлы для хранения прогресса и прочего.
$stash_folder = [ordered]@{
    default       = "$PSScriptRoot/stash"                   # Общий путь к папке.
    tmp_folder    = "$PSScriptRoot/stash/tmp_folder"        # Каталог временного хранения торрент-файлов.
    archived      = "$PSScriptRoot/stash/archived"          # Путь к спискам архивов по дискам.
    archived_list = "$PSScriptRoot/stash/archived_list.xml" # Локальный общий список сществующих в облаке архивов.
    uploads_limit = "$PSScriptRoot/stash/uploads_limit.xml" # Файл записанных отдач (лимиты).
    pause         = "$PSScriptRoot/stash/pause.txt"         # Если в файле что-то есть, скрипт встанет на паузу.

    downloaded    = $null
    backup_list   = $null
    finished_list = $null
}


$measure_names = @{
    byte_2   = @{ base = 1024; names = 'B','KiB','MiB','GiB','TiB','PiB' }
    byte_10  = @{ base = 1000; names = 'B','KB', 'MB', 'GB', 'TB', 'PB' }
    speed_2  = @{ base = 1024; names = 'B/s','KiB/s','MiB/s','GiB/s','TiB/s','PiB/s' }
    speed_10 = @{ base = 1000; names = 'B/s','KB/s' ,'MB/s' ,'GB/s' ,'TB/s' ,'PB/s' }
    time     = @{ base = 60;   names = 'сек', 'мин', 'час' }
}


# Получить список существующих архивов из списков по дискам.
function Get-Archives ( [switch]$Force, [string[]]$Name ){
    Sync-ArchList -Force:$Force -Name:$Name

    Write-Host ''
    Write-Host '[archived] Смотрим, что уже заархивировано..'
    $archive = @{}
    # Пробуем вытащить готовый список
    if ( Test-Path $stash_folder.archived_list ) {
        try {
            $time_collect = [math]::Round( (Measure-Command {
                $restore = Import-Clixml -Path $stash_folder.archived_list
                if ( $restore.hashes ) {
                    $archive = $restore
                    $restore = $null
                }
            }).TotalSeconds, 1 )
            $time_parse = 0
        } catch {
        }
    }

    # Если списка нет или были обновления списков по дискам - собираем заново
    if ( !$archive.hashes ) {
        if ( !(Get-ChildItem $stash_folder.archived) ) { Exit }

        Write-Host '[archived] Собираем общий список из данных по каждому диску.'
        $time_collect = [math]::Round( (Measure-Command {
            $arch_dones = Get-Content ( $stash_folder.archived + $OS.fsep + '*.txt' )
            $arch_dones = [string[]]$arch_dones
        }).TotalSeconds, 1 )

        $time_parse = [math]::Round( (Measure-Command {
            $arch_hashes = @{}
            $arch_dones | % {
                $topic_id, $hash = ($_ -split '_',2).Trim()
                if ( $topic_id -And $hash ) {
                    $arch_hashes[$hash] = $topic_id
                }
            }
        }).TotalSeconds, 1 )

        $archive = @{ dones = $arch_dones; hashes = $arch_hashes }
        $archive | Export-Clixml -Path $stash_folder.archived_list
        $arch_dones = $arch_hashes = $null

    }
    Write-Host ( '[archived] Обнаружено архивов: {0} [{1} сек], хешей: {2} [{3} сек]' -f $archive.dones.count, $time_collect, $archive.hashes.count, $time_parse )
    return $archive.dones, $archive.hashes
}

# Обновить список архивов в локальной "БД".
function Sync-ArchList ( [switch]$Force, [string[]]$Name ) {
    $arch_folders = Get-ChildItem $google_params.folders[0] -Directory -Filter "$google_folder_prefix*"

    $decay_hours = $google_params.decay_hours
    if ( !$decay_hours ) { $decay_hours = 12 }
    if ( $Name )  { $decay_hours = [math]::Ceiling( $decay_hours / 2 ) }
    # Принудительно обновление.
    if ( $Force ) { $decay_hours = 2 }

    # Собираем список гугл-дисков и проверяем наличие файла со списком архивов для каждого. Создаём если нет.
    # Проверяем даты обновления файлов и размер. Если прошло decay_hours или файл пуст -> пора обновлять.
    $folders = $arch_folders | % { Watch-FileExist ($stash_folder.archived + $OS.fsep + $_.Name + '.txt') }
        | ? { $_.($OS.sizeField) -eq 0 -Or ($_.LastWriteTime -lt ( Get-Date ).AddHours( -$decay_hours )) }
        | Sort-Object -Property LastWriteTime

    # Если передан конкретный диск, обновляем только его.
    if ( $Name ) {
        $folders = $folders | ? { $_.BaseName -in $Name }
    }

    if ( !$folders ) { return }

    $updated = 0
    Write-Host ( '[archived] Обновляем списков: {0} шт.' -f $folders.count )
    foreach ( $folder in $folders ) {
        $arch_path = ( $arch_folders | ? { $folder.BaseName -eq $_.BaseName } ).FullName

        Write-Host ( '[archived][{0}] Начинаем обновление..' -f $folder.BaseName )
        $ls_time = [math]::Round((Measure-Command {
            # Ищем список файлов. ls Для линукс, gci для винды.
            if ( $OS.name -eq 'linux' ) {
                $zip_list = &{ ls -U $arch_path }
            } else {
                $zip_list = Get-ChildItem $arch_path -File -Filter '*.7z' | % { $_.Name }
            }
        }).TotalSeconds)
        $ls_time = Get-BaseSize $ls_time -SI time

        $rw_time = [math]::Round((Measure-Command {
            # Из полученных имён вытаскиваем базовое имя архива и пишем в файл.
            $regex = "^\d+_.*(?=\.7z)"
            $stream = [System.IO.StreamWriter] $folder.FullName;
            foreach( $zip_name in $zip_list ) {
                $zip_name = [regex]::matches($zip_name, $regex).value
                if ( $zip_name ) { $stream.WriteLine( $zip_name ) }
            }
            $stream.Close(); $stream.Dispose();
        }).TotalSeconds)
        $rw_time = Get-BaseSize $rw_time -SI time

        $updated += $zip_list.count
        $text = '[archived][{0}] Обновлено за {2}/{3}. Найдено архивов: {1} шт.'
        Write-Host ( $text -f $folder.BaseName, $zip_list.count, $ls_time, $rw_time )

        $zip_list = $null
    }

    if ( $updated ) {
        Clear-Content -Path $stash_folder.archived_list
    }
}


# Пробуем удалить раздачу из клиента, если подходит под параметры.
function Dismount-ClientTorrent ( [int]$torrent_id, [string]$torrent_hash, [string]$torrent_category = $null ) {
    if ( !$uploader.delete ) { return }
    if ( !$uploader.delete_category ) { return }

    # Если используется модуль пакетной очистки, то пишем в файлик.
    if ( $used_modules.cleaner ) {
        $finished_list = $stash_folder.finished_list
        Watch-FileExist $finished_list > $null

        ($torrent_id.ToString() + '_' + $torrent_hash.ToLower()) | Out-File $finished_list -Append
        return
    }

    # Удаляем раздачу из клиента.
    if ( !$torrent_category ) {
        $torrent = Get-ClientTorrents @( $torrent_hash )
        if ( !$torrent ) { return }
        $torrent_category = $torrent.category
    }

    if ( $uploader.delete_category -in $torrent_category ) {
        Remove-ClientTorrent $torrent_id $torrent_hash
    }
}

function Get-ClientProperty( [string]$Property ) {
    return $client[ $Property ]
}

# Вытащить ид раздачи из комментария.
function Get-TopicID ( [string]$Comment ) {
    if ( $Comment -match 'rutracker' ) {
        return ( Select-String "\d*$" -InputObject $comment ).Matches.Value
    }
}

# Найти ид раздач(топиков) в [списке архивов, комменте раздачи из клиента, api трекера].
# Если раздача уже есть в списке архивов, то она исключается из итогового набора раздач.
function Get-TopicIDs ( $torrents_list, $hashes ) {
    $filtered = @() # < Список раздач, требущих загрузки в облако.
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
            $forum_res = Get-ForumTopicId $torrent.hash
            $torrent.topic_id = $forum_res[ $torrent.hash ]
        }

        # исправление путей для кривых раздач с одним файлом в папке
        if ( ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '')) -match ('[\\/]') ) {
            $separator = $matches[0]
            $torrent.content_path = $torrent.save_path + $separator + ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '') -replace ('[\\/].*$', '') )
        }

        # для Unix нужно экранировать кавычки и пробелы.
        if ( $OS.name -eq 'linux' ) {
            $torrent.content_path = $torrent.content_path.replace('"','\"')
        }
        $filtered += $torrent
    }

    if ( $removed ) {
        Write-Host( '[skip] Пропущено раздач: {0}.' -f $removed )
    }

    return @( $filtered | ? { $_.topic_id } )
}

# Проверки содержимого раздачи.
function Test-TorrentContent ( $torrent ) {
    $topic_id     = $torrent.topic_id
    $content_path = $torrent.content_path

    if ( !$content_path ) {
        throw '[skip] Отсутсвует путь к содержимому раздачи. Пропускаем.'
    }
    if ( !(Test-Path -LiteralPath $content_path) ) {
        throw ( '[skip] Не удалось найти файлы раздачи, по указанному пути: [{0}]. Пропускаем.' -f $content_path )
    }

    # Проверим размер указанный в раздаче и размер фактического содержимого.
    $content_size = Get-FolderSize $content_path
    if ( $torrent.size -ne $content_size ) {
        throw ( '[skip] Размер раздачи {0} ({1}) указанный в клиенте, не совпадает с фактическим ({2}). Пропускаем.' -f $topic_id, $torrent.size, $content_size )
    }

    # Проверим раздачу на форуме.
    $forum_topic = ( Get-ForumTopics -Topics $topic_id ).topics
    if ( $torrent.hash -ne $forum_topic.hash ) {
        Write-Host ( 'client hash: {0}; forum hash: {1}' -f $torrent.hash, $forum_topic.hash )
        throw ( '[skip] Раздача {0} имеет другой хеш на форуме. Вероятно, она обновлена. Пропускаем.' -f $topic_id )
    }
    $torrent.forum_id = $forum_topic.forum_id
}

# Проверим пути хранения раздач, и если есть одинаковые - ошибка.
function Compare-UsedLocations ( $Torrents ) {
    $ok = $true
    # проверяем, что никакие раздачи не пересекаются по именам файлов (если файл один) или каталогов (если файлов много), чтобы не заархивировать не то
    Write-Host ( '[check] Проверяем уникальность путей сохранения раздач..' )

    $used_locs = @()
    foreach ( $torrent in $Torrents ) {
        if ( $used_locs -contains $torrent.content_path ) {
            Write-Host ( 'Несколько раздач хранятся по пути "' + $torrent.content_path + '" !')
            Write-Host ( 'Нажмите любую клавищу, исправьте и начните заново !')
            $ok = $false
        }
        else {
            $used_locs += $torrent.content_path
        }
    }
    If ( !$ok ) {
        pause
        Exit
    }
}

# Создаём новых архив.
function New-ZipTopic ( [string]$Path, [string]$Content, [int]$Compression, [int]$Cores ) {
    if ( !$Cores ) { $Cores = $backuper.cores }
    if ( $Cores -le 0 ) { $Cores = 1 }

    if ( $backuper.h7z ) {
        & $backuper.p7z a $Path $Content "-p$pswd" "-mx$Compression" ("-mmt" + $Cores) -mhe=on -sccUTF-8 -bb0 > $null
    } else {
        & $backuper.p7z a $Path $Content "-p$pswd" "-mx$Compression" ("-mmt" + $Cores) -mhe=on -sccUTF-8 -bb0
    }
}

# Распаковать содержимое архива по заданному пути.
function Restore-ZipTopic ( [string]$Path, [string]$Extract ) {
    New-Item -ItemType Directory -Path $Extract -Force > $null
    if ( $backuper.h7z ) {
        & $backuper.p7z x "$Path" "-p$pswd" "-aoa" "-o$Extract" > $null
    } else {
        & $backuper.p7z x "$Path" "-p$pswd" "-aoa" "-o$Extract"
    }
}

# Проверка целостности архива.
function Test-ZipIntegrity ( [string]$Path ) {
    if ( $backuper.h7z ) {
        & $backuper.p7z t $Path "-p$pswd" > $null
    } else {
        & $backuper.p7z t $Path "-p$pswd"
    }
}

# По ид раздачи вычислить путь к файлу в облаке.
function Get-TorrentPath ( [int]$topic_id, [string]$hash, [string]$google_folder = $null ) {
    $full_name = $topic_id.ToString() + '_' + $hash.ToLower() + '.7z'
    if ( !$google_folder ) {
        $google_folder = $google_params.folders[0]
    }
    $disk_id, $disk_name, $disk_path = Get-DiskParams $topic_id
    $Path = $google_folder + $disk_path + $full_name

    return $Path
}

# Получить список названий дисков, по списку раздач от трекера/клиента.
function Get-DiskList ( $TopicList ) {
    $topic_count = $TopicList.count
    $has_topic_id = ($TopicList | ? { $_.topic_id }).count

    # Если раздачи без ид, и их немного, дёрнем апи.
    if ( $topic_count -le 100 -and !$has_topic_id ) {
        $forum_res = Get-ForumTopicId ($TopicList | % { $_.hash })
        $topics = $forum_res.values
    } else {
        $topics = @( $TopicList | % { $_.topic_id } )
    }
    # Получаем уникальный список названий дисков по списку ид раздач.
    return $topics | % { $null, $disk_name, $null = Get-DiskParams $_; $disk_name } | Sort-Object -Unique
}

# По ид раздачи вычислить ид диска, название диска/папки, путь к диску
function Get-DiskParams ( [int]$topic_id ) {
    $topic_step = 300000
    $disk_id = [math]::Truncate( ( $topic_id - 1 ) / $topic_step ) # 1..24
    $disk_name = $google_folder_prefix + '_' + ( $topic_step * $disk_id + 1 ) + '-' + $topic_step * ( $disk_id + 1 )
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

# Вычисляем сжатие архива, в зависимости от раздела раздачи и параметров.
function Get-Compression ( $torrent, $params ) {
    try {
        $compression = $params.sections_compression[ [int]$torrent.forum_id ]
    } catch {}
    if ( $compression -eq $null ) { $compression = $params.compression }
    if ( $compression -eq $null ) { $compression = 1 }
    return $compression
}


# Подключаемся к форуму с логином и паролем.
function Initialize-Forum () {
    if ( !$forum ) {
        Write-Host '[forum] Не обнаружены данные для подключения к форуму. Проверьте настройки.'
        Exit
    }
    Write-Host '[forum] Авторизуемся на форуме.'

    $login_url = 'https://rutracker.org/forum/login.php'
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    $payload = @{ 'login_username' = $forum.login; 'login_password' = $forum.password; 'login' = '%E2%F5%EE%E4' }

    try {
        if ( $forum.proxy ) {
            $proxy_url = $forum.proxy_address
            Write-Host ( '[forum] Используем прокси {0}.' -f $proxy_url )

            $secure_pass = ConvertTo-SecureString -String $forum.proxy_password -AsPlainText -Force
            $proxy_creds = New-Object System.Management.Automation.PSCredential -ArgumentList $forum.proxy_login, $secure_pass
            $forum_auth = Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -Proxy $proxy_url -ProxyCredential $proxy_creds
        } else {
            $forum_auth = Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid
        }
        $match = Select-String "form_token: '(.*)'" -InputObject $forum_auth.Content
        $forum_token = $match.Matches.Groups[1].Value
    } catch {
        Write-Host ( '[forum] Ошибка авторизации: {0}' -f $Error[0] )
    }
    if ( !$forum_token ) {
        Write-Host '[forum] Не удалось авторизоваться на форуме.'
        Exit
    }
    $forum.token = $forum_token
    $forum.sid = $sid
    Write-Host ( '[forum] Успешно. Токен: [{0}]' -f $forum_token )
}

# Найти ид раздачи по хешу.
function Get-ForumTopicId ( [string[]]$hashes ) {
    $topics = @{}
    try {
        $forum_url = 'http://api.rutracker.org/v1/get_topic_id?by=hash&val={0}' -f ($hashes -Join ',')
        $result = ( ( Invoke-WebRequest $forum_url ).content | ConvertFrom-Json ).result

        $hashes | % { $topics[ $_ ] = $result.( $_ ) }
    } catch {
    }
    return $topics
}

# Скачать торрент-файл раздачи по ид, сложить во временную папку, вернуть ссылку
function Get-ForumTorrentFile ( [int]$Id, [string]$Type = 'temp' ) {
    if ( !$forum.sid ) { Initialize-Forum }

    $forum_url = 'https://rutracker.org/forum/dl.php?t=' + $Id
    $Path = $stash_folder.tmp_folder + $OS.fsep + $Id + '_' + $Type + '.torrent'
    New-Item -ItemType Directory -Path $stash_folder.tmp_folder -Force > $null
    Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path

    return Get-Item $Path
}

# Получить данные о раздачах по списку ид или форумов.
function Get-ForumTopics ( [int[]]$Topics, [int[]]$Forums, [int[]]$Status ) {
    # https://api.t-ru.org/v1/get_tor_status_titles
    $exclude_status = 5, 7

    $forum_topics = @()
    if ( $Topics.count -gt 0 ) {
        $request = @{ 'by' = 'topic_id'; 'val' = $Topics -Join ","}
        $tracker_result = ( Invoke-WebRequest -Uri 'https://api.t-ru.org/v1/get_tor_topic_data' -Body $request ).content | ConvertFrom-Json -AsHashtable

        $forum_topics = $tracker_result.result.GetEnumerator() | ? { $_.value } | % {
            @{
                topic_id = $_.key
                hash     = $_.value['info_hash'].toLower()
                seeders  = $_.value['seeders']
                size     = $_.value['size']
                priority = -1
                status   = $_.value['tor_status']
                forum_id = $_.value['forum_id']
                reg_time = $_.value['reg_time']
            }
        } | ? { $_.status -notin $exclude_status }
    }
    elseif ( $Forums.count -gt 0 ) {
        $Forums = $Forums | Sort-Object -Unique
        Write-Host ( '[forum] Получаем список раздач в разделах {0}' -f ($Forums -Join ",") )
        $forum_groups = @{}
        foreach ( $forum_id in $Forums ) {
            try {
                $tracker_result = ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $forum_id ) ).content | ConvertFrom-Json -AsHashtable
            } catch {
                Write-Host ( '[forum] Не найдены раздачи в разделе {0}' -f $forum_id )
                Continue
            }
            $topic_header = [ordered]@{}; $tracker_result.format.topic_id | % -Begin { $i = 0 } { $topic_header[$_] = $i++ }

            $temp_list = $tracker_result.result.GetEnumerator() | % {
               @{
                    topic_id = $_.key
                    hash     = $_.value[ $topic_header['info_hash'] ].toLower()
                    seeders  = $_.value[ $topic_header['seeders'] ]
                    size     = $_.value[ $topic_header['tor_size_bytes'] ]
                    priority = $_.value[ $topic_header['keeping_priority'] ]
                    status   = $_.value[ $topic_header['tor_status'] ]
                    forum_id = $forum_id
                    reg_time = $_.value[ $topic_header['reg_time'] ]
                }
            } | ? { $_.status -notin $exclude_status }

            Write-Host ( '- в разделе {0,4} имеется {1,6} раздач' -f $forum_id, $temp_list.count )

            $forum_groups[ $forum_id ] = $temp_list
            $forum_topics += $temp_list
        }
    }

    if ( $Status ) {
        $forum_topics = $forum_topics | ? { $_.status -in $Status }
    }
    return @{ topics = @( $forum_topics ); groups = $forum_groups }
}


# Ищем файлик с данными выгрузок в облако и получаем данные из него.
function Get-StoredUploads ( $uploads_old = @{} ) {
    $uploads_all = @{}
    If ( Test-Path $stash_folder.uploads_limit ) {
        try {
            $uploads_all = Import-Clixml -Path $stash_folder.uploads_limit
        } catch {}
    }
    if ( !$uploads_all ) { $uploads_all = $uploads_old }

    if ( $uploads_all ) {
        $yesterday = (Get-date).AddDays( -1 )
        # Чиним задвоение и убираем старые записи.
        $temp = @{}
        $uploads_all.keys | Sort-Object -Unique | % { $temp[$_] = @{} }
        $uploads_all.GetEnumerator() | ? { $_.value.count } | % {
            $cloud = $_.key
            $_.value.GetEnumerator() | ? { $_.key -and $_.key -ge $yesterday } | % {
                if ( !$temp[ $cloud ][ $_.key] ) {
                    $temp[ $cloud ] += @{ $_.key = $_.value }
                }
            }
        }
        $uploads_all = @{}
        $temp.GetEnumerator() | ? { $_.value.count } | % { $uploads_all[$_.key] = $_.value }
    }

    return $uploads_all
}

# Запишем текущие данные выгрузок в временный файлик.
function Write-StoredUploads ( $uploads_all = @{} ) {
    if ( !$uploads_all ) { exit }
    $uploads_all | Export-Clixml -Path $stash_folder.uploads_limit
}

# Записать размер выгруженного архива в файл и удалить старые записи.
function Get-TodayTraffic ( $CloudFolder, $FileSize = 0, $uploads_all ) {
    # Загружаем актуальные данные из файла.
    $uploads_all = Get-StoredUploads $uploads_all
    # Выбираем текущий путь.
    $uploads = $uploads_all[ $CloudFolder ]
    if ( !$uploads ) { $uploads = @{} }
    # Если размер файла не нулевой, дописываем его и пишем в файл.
    if ( $FileSize -gt 0 ) {
        $uploads[ (Get-date) ] = $FileSize
        $uploads_all[ $CloudFolder ] = $uploads
        Write-StoredUploads $uploads_all
    }
    # Возвращаем суммарый размер выгруженных файлов и общие данные.
    return ( $uploads.values | Measure-Object -Sum ).Sum, $uploads_all
}

# Проверим использованные лимиты выгрузки в облако.
function Compare-StoredUploads ( $CloudFolder ) {
    # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
    $today_size, $null = Get-TodayTraffic -CloudFolder $CloudFolder

    # Если за последние 24ч, по выбранному аккаунту, было отправлено более квоты, то ждём.
    while ( $today_size -gt $lv_750gb ) {
        Write-Host ( '[limit][{0:t}] {1} выгружено {2} за прошедшие 24ч. Пауза на час.' -f (Get-Date), $CloudFolder, (Get-BaseSize $today_size ) )
        Start-Sleep -Seconds ( 60 * 60 )

        Start-Pause
        $today_size, $null = Get-TodayTraffic -CloudFolder $CloudFolder
    }
    Write-Host ( '[limit][{0:t}] {1} выгружено {2}.' -f (Get-Date), $CloudFolder, (Get-BaseSize $today_size) )
}

# Отобразить затраченные лимиты в разрезе периодов времени.
function Show-StoredUploads ( $uploads_all ) {
    if ( !$uploads_all ) { Exit }

    # Считаем значения
    $time_diff = 1, 3, 6, 12
    $yesterday = ( Get-date ).AddDays( -1 )

    $upload_rows = @()
    $row_text = '[limit][{4,-16}] Выгружено {5,9} => [{0,9}| {1,9}| {2,9}| {3,9}]'
    $uploads_all.GetEnumerator() | Sort-Object Key | % {
        $period = [ordered]@{}
        $time_diff | % { $period[ [string]$_ ] = 0 }

        $disk_name = $_.key
        $upload    = $_.value

        $actual = @{}
        $upload.GetEnumerator() | ? { $_.key -ge $yesterday } | % { $actual[$_.key] = $_.value }
        $full_size = ( $actual.values | Measure-Object -sum ).Sum

        # Если общий размер пуст, выводить не нужно.
        if ( $full_size ) {
            foreach ( $tmsp in $upload.keys ) {
                foreach ( $h in $time_diff ) {
                    if ( $tmsp -le $yesterday.addHours( $h ) ) {
                        $period[ [string]$h ] += $upload[$tmsp]
                        Break
                    }
                }
            }
            $upload_rows += ( $row_text -f @( ($period.values | % {Get-BaseSize $_}) + $disk_name + (Get-BaseSize $full_size) ) )
        }
    }
    if ( $upload_rows ) {
        Write-Host ( '[limit] Текущие использованные лимиты выгрузки (освободится через [1,3,6,12] часов):' ) -ForegroundColor Yellow
        $upload_rows | Write-Host
        Write-Host ''
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
function Get-BaseSize ( [long]$Size, [int]$pow = 0, $SI = 'byte_2', [int]$Precision = 1 ) {
    $measure = $measure_names[$SI]
    if ( !$measure ) { $measure = $measure_names.byte_2 }

    $val = 0
    if ( $Size -gt 0 ) {
        if ( $pow -le 0 ) {
            $pow = [math]::Floor( [math]::Log( $Size, $measure.base) )
        }
        if ( $pow -gt $measure.names.count - 1 ) {
            $pow = $measure.names.count - 1
        }
        $val = [math]::Round( $Size / [math]::Pow($measure.base, $pow), $Precision)
    }

    return ( $val ).ToString() + ' ' + $measure.names[ $pow ]
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
    $temp_folder_size = 0
    if ( $Path ) {
        New-Item -ItemType Directory $Path -Force > $null
        $temp_folder_size = (Get-ChildItem -LiteralPath $Path -File -Recurse | Measure-Object -Property $OS.sizeField -Sum).Sum
    }
    if ( !$temp_folder_size ) { $temp_folder_size = 0 }
    return $temp_folder_size
}

# Сравнить размер каталогов с максимально допустимым.
function Compare-MaxSize ( [string]$Path, [long]$MaxSize, [long]$FileSize = 0 ) {
    $wait_time = 1 #мин
    while ( $true ) {
        $folder_size = Get-FolderSize $Path
        if ( ($folder_size + $FileSize) -le $MaxSize ) {
            break
        }

        $file_text = ( $FileSize -gt 0 ) ? ("Файл размером {0} не влезет." -f (Get-BaseSize $FileSize)) : ""
        $limit_text = '[limit][{0}] Допустимый размер каталога [{1}]: {2}. Занято {3}. {4} Подождём {5} мин, пока освободится.'
        Write-Host ( $limit_text -f (Get-Date -Format t), $Path, (Get-BaseSize $MaxSize), (Get-BaseSize $folder_size), $file_text, $wait_time )
        Start-Sleep -Seconds ( 60 * $wait_time )

        # Увеличиваем интервал ожидание от 1 до 10 минут.
        if ( $wait_time -lt 10 ) { $wait_time += 1 }
    }
}

# Собрать путь хранения добавляемой в клиент раздачи.
function Get-TopicDownloadPath ( $Params, [int]$topic_id ) {
    # Если в параметрах не указно место хранение, возьмём стандартный путь из клиента.
    if ( !$Params.path ) {
        $Params.path = Get-ClientDownloadDir
    }

    $download_dir = $Params.path
    if ( $Params.sub_folder ) {
        $download_dir = $Params.path + $OS.fsep + $topic_id
    }
    return $download_dir
}

# Удаление пустых каталогов по заданному пути.
function Clear-EmptyFolders ( $Path ) {
    if ( !$Path ) { return }
    if ( Test-Path $Path ) {
        Get-ChildItem $Path -Directory | ? { (Get-ChildItem -LiteralPath $_.Fullname).count -eq 0 } | % { Remove-Item $_.Fullname -Force } > $null
    }
}

# Проверка наличия архива по заданному пути с выводом таймеров.
function Test-CloudPath ( [string]$Path ) {
    Write-Host ( '[cloud] Проверяем путь к архиву в облаке: {0}' -f $Path )
    $exec_time = [math]::Round( (Measure-Command {
        $result = Test-Path $Path
    }).TotalSeconds, 1 )

    $size = $result ? (Get-Item $Path).Length : 0
    $resultText = $result ? ( 'имеется ({0})' -f (Get-BaseSize $size)) : 'отсутсвует'
    Write-Host ( '[cloud] Проверка выполнена за {0}, архив в облаке {1}' -f (Get-BaseSize $exec_time -SI time), $resultText )


    return @{ result = $result; size = $size; exec = $exec_time }
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
    Watch-FileExist $pause_path > $null
    while ( $true ) {
        $needSleep = $false
        $pausetime = 0

        # Если есть файлик и в нём есть содержимое - ставим скрипт на паузу.
        If ( Test-Path $pause_path ) {
            $pause = ( Get-Content $pause_path | Select-Object -First 1 )
            if ( !($pause -eq $null) ) {
                $needSleep = $true
                $pausetime = $pause -as [int]
                if ( $pausetime -eq $null ) {
                    $pausetime = 5 # Дефолтное значение 5 минут.
                }
            }
        }
        if ( $needSleep -and $pausetime -gt 0) {
            Write-Host ( '[paused] Тормозим на ' + $pausetime + ' минут.' )
            Start-Sleep -Seconds ($pausetime * 60)
        } else {
            break
        }
    }
}


# Проверка/валидация настроек.
function Sync-Settings ( [string]$Mode ) {
    # Определяем параметры окружения.
    Get-OsParams

    $terminate = $false
    $errors = @()
    if ( !$client ) {
        $errors+= '[settings][client] Отсутсвует блок параметров подключения к клиенту'
        $terminate = $true
    } else {
        if ( !$client.type ) {
            $errors+= '[settings] Не указан тип клиента, $client.type'
            $terminate = $true
        } else {
            $client_file = "$PSScriptRoot\clients\client.{0}.ps1" -f $client.type.ToLower()
            if ( !(Test-Path $client_file) ) {
                $errors+= '[client] Выбранный торрент-клиент {0} не обнаружен или не поддерживается!' -f $client.type
                $terminate = $true
            }
        }
    }

    # Валидация настроек гугл-диска.
    if ( !$google_params ) {
        $errors+= '[settings][google_params] Отсутсвует блок параметров гугл-дисков'
        $terminate = $true
    } else {
        # Проверяем наличие нужного количества каталогов.
        if ( $google_params.folders ) {
            $disk_count = 24
            $err = 'В каталоге гугл-диска "{0}" недостаточно подключенных дисков ({1} из {2}). Проверьте настройки подключения.'
            $google_params.folders | % {
                $dir_count = (Get-ChildItem $_ -Directory -Filter "$google_folder_prefix*").count
                if ( $dir_count -ne $disk_count ) {
                    $errors += $err -f $_, $dir_count, $disk_count
                    $terminate = $true
                }
            }
        }

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
        $errors+= '[settings][backuper] Отсутсвует блок параметров архивирования'
        $terminate = $true
    }

    if ( !$uploader ) {
        $errors+= '[settings][uploader] Отсутсвует блок параметров выгрузки на гугл-диск'
    }

    if ( !$collector ) {
        $errors+= '[settings][collector] Отсутсвует блок параметров загрузки торрент-файлов'
        if ( $Mode -eq 'RT_collector' ) { $terminate = $true }
    }

    if ( !$forum ) {
        $errors+= '[settings][forum] Отсутсвует блок параметров подключения к форуму'
        if ( $Mode -eq 'RT_collector' ) { $terminate = $true }
    }

    if ( $errors ) {
        if ( $terminate ) { $errors += 'Проверьте файл настроек.'}
        $errors | Write-Host -ForegroundColor Yellow
    }

    # Проверим наличие заданных каталогов. (вероятно лучше перенести в проверку конфига)
    New-Item -ItemType Directory -Path $def_paths.progress -Force > $null
    New-Item -ItemType Directory -Path $def_paths.finished -Force > $null
    New-Item -ItemType Directory -Path $stash_folder.archived -Force > $null

    return !$terminate
}

function Select-Client ( [Parameter (Mandatory = $true)][string]$ClientName ) {
    if ( $client_list.count ) {
        if ( $ClientName ) {
            $client = $client_list | ? { $_.name -eq $ClientName }
        }
        if ( !$client ) { $client = $client_list[0] }
    }

    if ( $client.type ) {
        return $client
    }
}

function Connect-Client {
    Write-Verbose 'client connect start'
    if ( !$client.name -And $client.type ) {
        $client.name = $client.type
    }

    $stash_folder.downloaded    = $def_paths.downloaded    -f $client.name
    $stash_folder.backup_list   = $def_paths.backup_list   -f $client.name
    $stash_folder.finished_list = $def_paths.finished_list -f $client.name

    $client_file = "$PSScriptRoot\clients\client.{0}.ps1" -f $client.type.ToLower()
    if ( Test-Path $client_file ) {
        Write-Host ( '[client] Выбранный торрент-клиент "{0}" [{1}], подключаем модуль.' -f $client.name, $client.type ) -ForegroundColor Green
        Write-Verbose 'client connect end'
        return $client_file
    }
}


# Подключаем файл с функциями выбранного клиента, если он есть.
if ( $client.type -and !$NoClient ) {
    Write-Verbose 'client init start'
    . (Connect-Client)
    Write-Verbose 'client init end'
}
