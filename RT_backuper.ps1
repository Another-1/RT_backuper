. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'; Pause; Exit }

$os, $folder_sep = Get-OsParams

Start-Pause
Clear-Host

# Очищаем пустые папки в папке загрузок
Clear-EmptyFolders $store_path

Write-Host '[backuper] Авторизуемся в клиенте.'
try {
    $sid = Initialize-Client
} catch {
    Write-Host ( 'Авторизация не удалась. {0}' -f $Error[0] ) -ForegroundColor Red
    Exit
}

# Пробуем найти список раздач, которые обрабатывались, но процесс прервался.
try { $torrents_list = Import-Clixml $stash_folder.backup_list } catch {}

# Если список пуст, начинаем с начала.
if ( !$torrents_list ) {
    $dones, $hashes = Get-Archives

    # получаем список раздач из клиента
    Write-Host 'Получаем список раздач из клиента..'
    $torrents_list = Get-ClientTorrents $client_url $sid $args

    if ( $torrents_list -eq $null ) {
        Write-Host 'Не удалось получить раздачи!'
        Exit
    }
    Write-Host ( '..от клиента получено раздач: {0}.' -f $torrents_list.count )

    # по каждой раздаче получаем коммент, чтобы достать из него номер топика
    Write-Host ( 'Получаем номера топиков по раздачам..' )
    $torrents_list = Get-TopicIDs $torrents_list
    Write-Host ( '..топиков с номерами получено: {0}.' -f $torrents_list.count )


    # отбросим раздачи, для которых уже есть архив с тем же хэшем
    Write-Host 'Пропускаем уже заархивированные раздачи..'
    $was = $torrents_list.count
    $torrents_list = Get-Required $torrents_list $dones

    if ( $was -ne $torrents_list.count ) {
        Write-Host( '..пропущено раздач: {0}.' -f ($was - $torrents_list.count) )
    }
}

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true
Write-Host ( '[backuper] Объём новых раздач ({0} шт) {1}.' -f $sum_cnt, (Get-FileSize $sum_size) )

# проверяем, что никакие раздачи не пересекаются по именам файлов (если файл один) или каталогов (если файлов много), чтобы не заархивировать не то
Write-Host ( 'Проверяем уникальность путей сохранения раздач..' )

foreach ( $torrent in $torrents_list ) {
    if ( $used_locs.keys -contains $torrent.content_path ) {
        Write-Host ( 'Несколько раздач хранятся по пути "' + $torrent.content_path + '" !')
        Write-Host ( 'Нажмите любую клавищу, исправьте и начните заново !')
        $ok = $false
    }
    else { $used_locs += $torrent.content_path }
}
If ( $ok -eq $false) {
    pause
    Exit
}

# Проверим наличие заданных каталогов. (вероятно лучше перенести в проверку конфига)
New-Item -ItemType Directory -Path $arch_params.progress -Force | Out-Null
New-Item -ItemType Directory -Path $arch_params.finished -Force | Out-Null

Write-Host ('[backuper] Начинаем перебирать раздачи.')
# Перебираем найденные раздачи и бекапим их.
$torrents_left = $torrents_list
$torrents_left | Export-Clixml $stash_folder.backup_list
foreach ( $torrent in $torrents_list ) {
    # Проверка на переполнение каталога с архивами.
    while ( $true ) {
        $folder_size = Get-FolderSize $arch_params.finished
        if ( !(Compare-MaxFolderSize $folder_size $arch_params.finished_size) ) {
            break
        }
        $text = '[limit][{0}] Занятый объём каталога ({1}) {2} больше допустимого {3}. Подождём пока освободится.'
        Write-Host ($text -f (Get-Date -Format t), $arch_params.finished, (Get-FileSize $folder_size), (Get-FileSize $arch_params.finished_size) )
        Start-Sleep -Seconds 60
    }

    # Ид раздачи
    $torrent_id = $torrent.state
    $torrent_hash = $torrent.hash.ToLower()
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id $folder_sep

    # Имя арихва.
    $zip_name = $torrent_id.ToString() + '_' + $torrent.hash.ToLower() + '.7z'

    # Полный путь хранения обрабатываемого архива и архива, который готов к заливке.
    $zip_path_progress = $arch_params.progress + $folder_sep + $zip_name
    $zip_path_finished = $arch_params.finished + $folder_sep + $zip_name
    $zip_google_path   = $google_params.folders[0] + $disk_path + $zip_name

    Start-Pause
    Write-Host ''
    Write-Host ( '[torrent] Архивируем {0} ({2}), {1} ' -f $torrent_id, $torrent.name, (Get-FileSize $torrent.size) ) -ForegroundColor Green

    try {
        # Проверяем, что архив для такой раздачи ещё не создан.
        $zip_test = Test-PathTimer $zip_google_path
        Write-Host ( '[check][{0}] Проверка в гугле заняла {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
        if ( $zip_test.result ) {
            # Если раздача уже есть в гугле, то надо её удалить из клиента и добавить в локальный список архивированных.
            Dismount-ClientTorrent $torrent_id $torrent_hash
            throw '..раздача уже имеет архив в гугле, пропускаем.'

        }
        if ( Test-Path $zip_path_finished ) {
            throw '..раздача уже имеет архив ожидающий переноса в гугл, пропускаем.'
        }

        # Удаляем файл в месте архивирования, если он прочему-то есть.
        if ( Test-Path $zip_path_progress ) { Remove-Item $zip_path_progress | Out-Null }

        # для Unix нужно экранировать кавычки и пробелы.
        if ( $os -eq 'linux' ) { $torrent.content_path = $torrent.content_path.replace('"','\"') }
        # Начинаем архивацию файла
        $compression = Get-Compression $torrent_id $arch_params
        $start_measure = Get-Date
        & $7z_path a $zip_path_progress $torrent.content_path "-p$pswd" "-mx$compression" ("-mmt" + $arch_params.cores) -mhe=on -sccUTF-8 -bb0
        if ( $LastExitCode -ne 0 ) {
            Remove-Item $zip_path_progress
            throw ( 'Архивация завершилась ошибкой: {0}. Удаляем файл.' -f $LastExitCode )
        }

        # Считаем результаты архивации
        $time_arch = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
        $zip_size = (Get-Item $zip_path_progress).Length
        $comp_perc = [math]::Round( $zip_size * 100 / $torrent.size )
        $speed_arch = (Get-FileSize ($torrent.size / $time_arch) -SI speed_2)

        $success_text = '[torrent] Успешно завершено за {0} сек [comp:{1}, cores:{2}, archSize:{3}, perc:{4}, speed:{5}]'
        Write-Host ( $success_text -f $time_arch, $compression, $arch_params.cores, (Get-FileSize $zip_size), $comp_perc, $speed_arch )

        try {
            if ( Test-Path $zip_path_finished ) { Remove-Item $zip_path_finished | Out-Null }
            Write-Host ( 'Перемещаем {0} в каталог {1}' -f  $zip_name, $arch_params.finished )
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
    Write-Host ( $text -f ++$proc_cnt, (Get-FileSize $proc_size), $sum_cnt, (Get-FileSize $sum_size) ) -ForegroundColor DarkCyan

    # Перезаписываем данные раздач, которые осталось обработать.
    $torrents_left = $torrents_left | ? { $_.state -ne $torrent_id } | Export-Clixml $stash_folder.backup_list

    Start-Stopping
    Start-Pause
}
# end foreach
