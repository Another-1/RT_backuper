Param (
    [string]$Hashes = $null,
    [string]$UsedClient = $null
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
    $hash_file = Watch-FileExist $def_paths.downloaded
    if ( $hash_file.($OS.sizeField) ) {
        $hash_list = ( Get-FileFirstContent $def_paths.downloaded $backuper.hashes_step )
        Write-Host ( '[backuper] Найдено раздач, докачанных клиентом : {0}.' -f $hash_list.count )
    }
    if ( !$hash_list -And $backuper.hashes_only ) {
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
Write-Host ( '[backuper] Раздач получено: {0} [{1} сек].' -f $torrents_list.count, $exec_time )

# Если нужно будет перебирать много раздач, то загружаем списки заархивированных.
if ( !$hash_list ) {
    $dones, $hashes = Get-Archives
}

# Фильтруем список раздач и получаем их ид.
Write-Host ( '[backuper] Получаем номера топиков по раздачам и пропускаем уже заархивированное.' )
$exec_time = [math]::Round( (Measure-Command {
    $torrents_list = Get-TopicIDs $torrents_list $hashes
}).TotalSeconds, 1 )
Write-Host ( '[backuper] Топиков с номерами получено: {0} [{1} сек].' -f $torrents_list.count, $exec_time )

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
Write-Host ('[backuper] Начинаем перебирать раздачи.')
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
    $base_name = $torrent_id.ToString() + '_' + $torrent.hash.ToLower()
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
    $zip_google_path   = $google_path + $disk_path + $full_name

    Start-Pause
    Write-Host ( '[torrent] Архивируем {0} ({2}), {1} ' -f $torrent_id, $torrent.name, (Get-BaseSize $torrent.size) ) -ForegroundColor Green

    try {
        Write-Host ( 'Проверяем гугл-диск {0}' -f $zip_google_path )
        # Проверяем, что архив для такой раздачи ещё не создан.
        $zip_test = Test-PathTimer $zip_google_path
        Write-Host ( '[check][{0}] Проверка выполнена за {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
        if ( $zip_test.result ) {
            # Если раздача уже есть в гугле, то надо её удалить из клиента и добавить в локальный список архивированных.
            Dismount-ClientTorrent $torrent_id $torrent_hash
            throw '[skip] Раздача уже имеет архив в гугле, пропускаем.'
        }

        # Удаляем файл в месте архивирования, если он прочему-то есть.
        if ( Test-Path $zip_path_progress ) { Remove-Item $zip_path_progress }

        $compression = Get-Compression $torrent_id $backuper
        $start_measure = Get-Date

        # Начинаем архивацию файла
        Write-Host ( '[torrent] Архивация начата, сжатие:{0}.' -f $compression )
        if ( $backuper.h7z ) {
            & $backuper.p7z a $zip_path_progress $torrent.content_path "-p$pswd" "-mx$compression" ("-mmt" + $backuper.cores) -mhe=on -sccUTF-8 -bb0 > $null
        } else {
            & $backuper.p7z a $zip_path_progress $torrent.content_path "-p$pswd" "-mx$compression" ("-mmt" + $backuper.cores) -mhe=on -sccUTF-8 -bb0
        }

        if ( $LastExitCode -ne 0 ) {
            Remove-Item $zip_path_progress
            throw ( '[skip] Архивация завершилась ошибкой: {0}. Удаляем файл.' -f $LastExitCode )
        }

        # Считаем результаты архивации
        $time_arch = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
        $zip_size = (Get-Item $zip_path_progress).Length
        $comp_perc = [math]::Round( $zip_size * 100 / $torrent.size )
        $speed_arch = (Get-BaseSize ($torrent.size / $time_arch) -SI speed_2)

        $success_text = '[torrent] Успешно завершено за {0} сек [archSize:{3}, cores:{2}, comp:{1}, perc:{4}, speed:{5}]'
        Write-Host ( $success_text -f $time_arch, $compression, $backuper.cores, (Get-BaseSize $zip_size), $comp_perc, $speed_arch )


        # Перед переносом проверяем доступный трафик.
        Compare-UsedLimits $google_name $uploads_all

        # Проверка переполнения каталога с кешем гугла.
        if ( $google_params.cache_size ) {
            Compare-MaxSize $google_params.cache $google_params.cache_size
        }

        Write-Host ( 'Проверяем гугл-диск {0}' -f $zip_google_path )
        $zip_test = Test-PathTimer $zip_google_path
        Write-Host ( '[check][{0}] Проверка выполнена за {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
        if ( $zip_test.result ) {
            Dismount-ClientTorrent $torrent_id $torrent_hash
            throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
        }

        try {
            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force > $null

            $move_sec = [math]::Round( (Measure-Command {
                Move-Item -Path $zip_path_progress -Destination ( $zip_google_path ) -Force -ErrorAction Stop
            }).TotalSeconds, 1 )
            if ( !$move_sec ) {$move_sec = 0.1}

            $speed_move = (Get-BaseSize ($zip_size / $move_sec) -SI speed_2)
            Write-Host ( '[uploader] Готово! Завершено за {0} минут, средняя скорость {1}' -f [math]::Round($move_sec/60, 1) , $speed_move )

            Dismount-ClientTorrent $torrent_id $torrent_hash

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip_size $google_name > $null
        }
        catch {
            Write-Host '[uploader] Не удалось отправить файл на гугл-диск'
            Write-Host ( '{0} => {1}' -f $zip_path_progress, $zip_google_path )
            Pause
        }
    } catch {
        if ( Test-Path $zip_path_progress ) { Remove-Item $zip_path_progress }
        Write-Host $Error[0] -ForegroundColor Red
    }

    Dismount-ClientTorrent $torrent_id $torrent_hash $torrent.category

    $proc_size += $torrent.size
    $text = 'Обработано раздач {0} ({1}) из {2} ({3})'
    Write-Host ( $text -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan

    Start-Pause
    Start-Stopping

    Sync-ArchList
}
# end foreach
