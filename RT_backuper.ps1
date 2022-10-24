. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

Start-Pause
Start-Stopping

$ScriptName = $PSCommandPath

# Пробуем найти список раздач, которые обрабатывались, но процесс прервался.
try {
    $backup_list_name = $client.name
    $current_backup_list = $stash_folder.backup_list -f $backup_list_name

    # Миграция старого файла бекапа
    $old_backup_list = $stash_folder.backup_list -f 'list'
    if ( Test-Path $old_backup_list ) { Rename-Item $old_backup_list $current_backup_list }

    $torrents_list = Import-Clixml $current_backup_list
    if ( $torrents_list ) {
        Write-Host ( '[backuper] Найдены недообработанные раздачи: {0}' -f $torrents_list.count )
    }
} catch {}

# Если список пуст, начинаем с начала.
if ( !$torrents_list ) {
    # Ищем раздачи, которые скачал клиент и добавил в буферный файл.
    $hash_file = Watch-FileExist $def_paths.downloaded
    if ( $hash_file.($OS.sizeField) ) {
        $downloaded = ( Get-FileFirstContent $def_paths.downloaded $backuper.hashes_step )
        Write-Host ( '[backuper] Найдено раздач, докачанных клиентом : {0}.' -f $downloaded.count )
    }

    if ( !$downloaded -And $backuper.hashes_only ) {
        Write-Host '[backuper] В конфиге обнаружена опция [hashes_only], прерываем.'
        Exit
    }

    # Подключаемся к клиенту.
    Initialize-Client

    # получаем список раздач из клиента
    Write-Host 'Получаем список раздач из клиента..'
    $exec_time = [math]::Round( (Measure-Command {
        $torrents_list = Get-ClientTorrents $downloaded
    }).TotalSeconds, 1 )

    if ( $torrents_list -eq $null ) {
        Write-Host 'Не удалось получить раздачи!'
        Exit
    }
    Write-Host ( '[backuper] Раздач получено: {0} [{1} сек].' -f $torrents_list.count, $exec_time )

    # Загружаем списки заархивированных раздач, чтобы отфильтровать.
    $dones, $hashes = Get-Archives

    # Фильтруем список раздач и получаем их ид.
    Write-Host ( 'Получаем номера топиков по раздачам и пропускаем уже заархивированное.' )
    $exec_time = [math]::Round( (Measure-Command {
        $torrents_list = Get-TopicIDs $torrents_list $hashes
    }).TotalSeconds, 1 )
    Write-Host ( '[backuper] Топиков с номерами получено: {0} [{1} сек].' -f $torrents_list.count, $exec_time )
}

# проверяем, что никакие раздачи не пересекаются по именам файлов (если файл один) или каталогов (если файлов много), чтобы не заархивировать не то
Compare-UsedLocations $torrents_list

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object size -Sum ).Sum
$sum_cnt = $torrents_list.count
Write-Host ( '[backuper] Объём раздач: {0} ({1}).' -f $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan
if ( !$sum_cnt ) { Exit }

# Записываем найденные раздачи в файлик.
$torrents_left = $torrents_list
$torrents_left | Export-Clixml $current_backup_list

# Перебираем найденные раздачи и бекапим их.
Write-Host ('[backuper] Начинаем перебирать раздачи.')
foreach ( $torrent in $torrents_list ) {
    Write-Host ''
    # Проверка на переполнение каталога с архивами.
    if ( $backuper.zip_folder_size ) {
        Compare-MaxSize $backuper.zip_folder $backuper.zip_folder_size
    }

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

    # Полный путь хранения обрабатываемого архива и архива, который готов к заливке.
    $zip_path_progress = $def_paths.progress + $OS.fsep + $full_name
    $zip_path_finished = $def_paths.finished + $OS.fsep + $full_name
    $zip_google_path   = $google_params.folders[0] + $disk_path + $full_name

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

        if ( Test-Path $zip_path_finished ) {
            throw '[skip] Раздача уже имеет архив ожидающий переноса в гугл, пропускаем.'
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

        try {
            if ( Test-Path $zip_path_finished ) { Remove-Item $zip_path_finished }
            Write-Host ( 'Перемещаем {0} в каталог {1}' -f  $base_name, $def_paths.finished )
            Move-Item -path $zip_path_progress -destination $zip_path_finished -Force -ErrorAction Stop
            Write-Host 'Готово!'
        }
        catch {
            Write-Host 'Не удалось переместить архив.' -ForegroundColor Red
            Pause
        }
    } catch {
        Write-Host $Error[0] -ForegroundColor Red
    }

    $proc_size += $torrent.size
    $text = 'Обработано раздач {0} ({1}) из {2} ({3})'
    Write-Host ( $text -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan

    # Перезаписываем данные раздач, которые осталось обработать.
    $torrents_left = $torrents_left | ? { $_.topic_id -ne $torrent_id }
    $torrents_left | Export-Clixml $current_backup_list

    Start-Pause
    Start-Stopping

    Sync-ArchList
}
# end foreach
