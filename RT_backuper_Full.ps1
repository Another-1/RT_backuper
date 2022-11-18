Param (
    [string]$Hashes = $null,
    [switch]$Verbose,

    [ArgumentCompleter({ param($cmd, $param, $word) [array](Get-Content "$PSScriptRoot/clients.txt") -like "$word*" })]
    [string]
    $UsedClient
)

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

Start-Pause
Start-Stopping

$ScriptName = $PSCommandPath

# Если переданы хеши как аргументы.
if ( $Hashes ) {
    $hash_list = $Hashes -Split ","
    Write-Host ( '[backuper] Переданы хешы: {0}, обработаем их.' -f ($hash_list -Join "|") )
}

# Если список пуст, начинаем с начала.
if ( !$hash_list ) {
    # Ищем раздачи, которые скачал клиент и добавил в буферный файл.
    $hash_file = Watch-FileExist $stash_folder.downloaded
    if ( $hash_file.($OS.sizeField) ) {
        $hash_list = ( Get-FileFirstContent $stash_folder.downloaded $backuper.hashes_step )
        Write-Host ( '[backuper] Найдено раздач, докачанных клиентом : {0}.' -f $hash_list.count )
    }
    if ( !$hash_list -And (Get-ClientProperty 'hashes_only') ) {
        Write-Host '[backuper] В конфиге обнаружена опция [hashes_only], прерываем.'
        Exit
    }
}

# Подключаемся к клиенту.
Initialize-Client

# получаем список раздач из клиента
Write-Host '[backuper] Получаем список раздач из клиента..'
$exec_time = [math]::Round( (Measure-Command {
    $torrents_list = Get-ClientTorrents $hash_list
}).TotalSeconds, 1 )

if ( $torrents_list -eq $null ) {
    Write-Host '[backuper] Раздачи не получены.'
    Exit
}
Write-Host ( '[backuper] Раздач получено: {0} [{1}].' -f $torrents_list.count, (Get-BaseSize $exec_time -SI time) )

# Если нужно будет перебирать много раздач, то загружаем списки заархивированных.
if ( !$hash_list ) {
    # Получаем список дисков, которые нужно обновить для текущего набора раздач.
    $disk_names = Get-DiskList $torrents_list
    # Получаем список существующих архивов.
    $done_list, $done_hashes = Get-Archives -Name $disk_names
}

# Фильтруем список раздач и получаем их ид.
Write-Host ( '[backuper] Получаем номера топиков по раздачам и пропускаем уже заархивированное.' )
$exec_time = [math]::Round( (Measure-Command {
    $torrents_list = Get-TopicIDs $torrents_list $done_hashes
}).TotalSeconds, 1 )
Write-Host ( '[backuper] Топиков требущих выгрузки обнаружено: {0} [{1}].' -f $torrents_list.count, (Get-BaseSize $exec_time -SI time) )

# проверяем, что никакие раздачи не пересекаются по именам файлов (если файл один) или каталогов (если файлов много), чтобы не заархивировать не то
if ( !$Hashes ) {
    Compare-UsedLocations $torrents_list
}

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object size -Sum ).Sum
$sum_cnt = $torrents_list.count
Write-Host ( '[backuper] Найдено раздач: {0} ({1}).' -f $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan
if ( !$sum_cnt ) { Exit }


# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
Show-StoredUploads $uploads_all

# Перебираем найденные раздачи и бекапим их.
Write-Host ( '[backuper][{0:t}] Начинаем перебирать раздачи.' -f (Get-Date) )
foreach ( $torrent in $torrents_list ) {
    Write-Host ''

    # Ид и прочие параметры раздачи.
    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash.ToLower()
    if ( !$torrent_id ) {
        Write-Host '[skip] Отсутсвует ид раздачи. Пропускаем.'
        Continue
    }


    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id

    # Имя архива.
    $base_name = $torrent_id.ToString() + '_' + $torrent_hash.ToLower()
    $full_name = $base_name + '.7z'


    # Если подключено несколько гугл-акков, по одному пути, вычисляем номер акка
    $order = Get-GoogleNum $disk_id $google_params.accounts_count

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $order.account - 1
    }

    $google_path = $google_params.folders[$folder_pointer]
    $google_name = ( '{0}({1})' -f $google_path, $order.account )

    # Полные пути к архиву этой итерации и итоговому месту хранения.
    $zip_path_progress = $def_paths.progress + $OS.fsep + $full_name
    $zip_path_finished = $def_paths.finished + $OS.fsep + $full_name
    $zip_google_path   = $google_path + $disk_path + $full_name

    Start-Pause
    Write-Host ( '[torrent][{0:t}] Обрабатываем {1} ({2}), {3} ' -f (Get-Date), $torrent_id, (Get-BaseSize $torrent.size), $torrent.name ) -ForegroundColor Green

    try {
        # Проверяем, что архив для такой раздачи ещё не создан.
        $zip_test = Test-CloudPath $zip_google_path
        if ( $zip_test.result ) {
            # Если раздача уже есть в гугле, то надо её удалить из клиента и добавить в локальный список архивированных.
            throw '[skip] Раздача уже имеет архив в гугле, пропускаем.'
        }

        $alreadyFinished = $false
        if ( Test-Path $zip_path_finished ) {
            Write-Host '[check] Найден архив для раздачи, проверим его..'
            Test-ZipIntegrity $zip_path_finished
            if ( $LastExitCode -ne 0 ) {
                Remove-Item $zip_path_finished
                Write-Host ( '[check] Архив не прошёл проверку, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
            } else {
                Write-Host ( '[check] Проверка успешно завершена, зальём готовый архив.' )

                $zip_size = (Get-Item $zip_path_finished).Length
                $alreadyFinished = $true
            }
        }

        # Удаляем файл в месте архивирования, если он прочему-то есть.
        if ( Test-Path $zip_path_progress ) { Remove-Item $zip_path_progress }

        # Если архива нет, создаём его и переносим в finished.
        if ( !$alreadyFinished ) {
            Test-TorrentContent $torrent

            # Проверка на переполнение каталога с архивами с учётом размера текущей раздачи.
            if ( $backuper.zip_folder_size ) {
                Compare-MaxSize -Path $backuper.zip_folder -MaxSize $backuper.zip_folder_size -FileSize $torrent.size
            }

            # Начинаем архивацию файла
            $compression = Get-Compression $torrent $backuper
            Write-Host ( '[torrent][{0:t}] Архивация начата, сжатие:{1}, ядра процессора:{2}.' -f (Get-Date), $compression, $backuper.cores )
            $start_measure = Get-Date

            New-ZipTopic $zip_path_progress $torrent.content_path $compression
            if ( $LastExitCode -ne 0 ) {
                if ( Test-Path $zip_path_progress ) { Remove-Item $zip_path_progress }
                throw ( '[skip] Архивация завершилась ошибкой: {0}. Удаляем файл.' -f $LastExitCode )
            }

            # Считаем результаты архивации
            $time_arch = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
            $zip_size = (Get-Item $zip_path_progress).Length
            $comp_perc = [math]::Round( $zip_size * 100 / $torrent.size )
            $speed_arch = (Get-BaseSize ($torrent.size / $time_arch) -SI speed_2)

            $success_text = '[torrent] Успешно завершено за {0} [archSize:{3}, cores:{2}, comp:{1}, perc:{4}, speed:{5}]'
            Write-Host ( $success_text -f (Get-BaseSize $time_arch -SI time), $compression, $backuper.cores, (Get-BaseSize $zip_size), $comp_perc, $speed_arch )

            if ( Test-Path $zip_path_finished ) { Remove-Item $zip_path_finished }
            Move-Item -Path $zip_path_progress -Destination $zip_path_finished -Force -ErrorAction Stop
        }

        # Перед переносом проверяем доступный трафик.
        Compare-StoredUploads $google_name $uploads_all

        # Проверка переполнения каталога с кешем гугла.
        if ( $google_params.cache_size ) {
            Compare-MaxSize $google_params.cache $google_params.cache_size
        }

        $zip_test = Test-CloudPath $zip_google_path
        if ( $zip_test.result ) {
            throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
        }

        try {
            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force > $null

            $move_sec = [math]::Round( (Measure-Command {
                Move-Item -Path $zip_path_finished -Destination $zip_google_path -Force -ErrorAction Stop
            }).TotalSeconds, 1 )
            if ( !$move_sec ) {$move_sec = 0.1}

            $speed_move = (Get-BaseSize ($zip_size / $move_sec) -SI speed_2)
            Write-Host ( '[uploader] Готово! Завершено за {0}, средняя скорость {1}' -f (Get-BaseSize $move_sec -SI time) , $speed_move )

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip_size $google_name > $null
        }
        catch {
            Write-Host '[uploader] Не удалось отправить файл на гугл-диск'
            Write-Host ( '{0} => {1}' -f $zip_path_finished, $zip_google_path )
            Pause
            Exit
        }
    } catch {
        if ( Test-Path $zip_path_finished ) { Remove-Item $zip_path_finished }
        Write-Host $Error[0] -ForegroundColor Red
    }

    # Проверим наличие раздачи в облаке. Если раздача есть, то можно пробовать удалить её из клиента.
    $zip_test = Test-CloudPath $zip_google_path
    if ( $zip_test.result ) {
        Dismount-ClientTorrent $torrent_id $torrent_hash $torrent.category
    }

    $proc_size += $torrent.size
    $text = '[backuper][{4:t}] Обработано раздач {0} ({1}) из {2} ({3})'
    Write-Host ( $text -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size), (Get-Date) ) -ForegroundColor DarkCyan

    Start-Pause
    Start-Stopping

    Sync-ArchList -Name $disk_name
}
# end foreach
