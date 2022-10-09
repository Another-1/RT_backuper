. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'; Pause; Exit }

$os, $folder_sep = Get-OsParams
if ( $PSVersionTable.OS.ToLower().contains('windows')) { $folder_sep = ':\' } else { $drive_separator = '/' }

Clear-Host
Start-Pause
Start-Stopping

# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | Sort-Object -Property Key | % {
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Host ( 'Для диска {0} выгружено: {1}' -f $_.key, ( Get-BaseSize $temp_size) )
}


$hash_list = @{}
# Если переданы хеши как аргументы.
if ( $args ) {
    $hash_list = $args | % { $_ }
    Write-Host ( 'Переданы хешы: {0}, обработаем их.' -f ($hash_list -Join "|") )
}

# Если список пуст, начинаем с начала.
if ( !$hash_list ) {
    # Ищем раздачи, которые скачал клиент и добавил в буферный файл.
    $hash_file = Watch-FileExist $def_paths.downloaded
    if ( $hash_file.Size ) {
        $downloaded = ( Get-FileFirstContent $def_paths.downloaded 20 )
        Write-Host ( '[backuper] Найдено раздач, докачанных клиентом : {0}.' -f $downloaded.count )
        if ( !$downloaded -And $backuper.hashes_only ) {
            Write-Host '[backuper] В конфиге обнаружена опция [hashes_only], прерываем.'
            Exit
        }

        $hash_list = $downloaded
    }
}

# Если нужно будет перебирать много раздач, то загружаем списки заархивированных.
if ( !$hash_list ) {
    $dones, $hashes = Get-Archives
}

Initialize-Client
# получаем список раздач из клиента
Write-Host 'Получаем список раздач из клиента..'
$exec_time = [math]::Round( (Measure-Command {
    $torrents_list = Get-ClientTorrents $hash_list
}).TotalSeconds, 1 )

if ( $torrents_list -eq $null ) {
    Write-Host 'Не удалось получить раздачи!'
    Exit
}
Write-Host ( '..от клиента получено раздач: {0} [{1} сек].' -f $torrents_list.count, $exec_time )

# по каждой раздаче получаем коммент, чтобы достать из него номер топика
Write-Host ( 'Получаем номера топиков по раздачам и пропускаем уже заархивированное.' )
$exec_time = [math]::Round( (Measure-Command {
    $torrents_list = Get-TopicIDs $torrents_list $hashes
}).TotalSeconds, 1 )
Write-Host ( 'Топиков с номерами получено: {0} [{1} сек].' -f $torrents_list.count, $exec_time )


$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true
Write-Host ( 'Объём новых раздач (' + $sum_cnt + ' шт) ' + ( Get-BaseSize $sum_size) + ' (' + $sum_size + ' B).' )

if ( $args.count -eq 0 ) {
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
}


# Проверяем наличие нового параметра в конфиге
if ( $google_params.accounts_count -eq $null -Or $google_params.accounts_count -gt 5 ) {
    $google_params.accounts_count = 1
}
# Если подключённых дисков больше одного, то кол-во акков = колву дисков
if ( $google_params.folders.count -gt 1 ) {
    $google_params.accounts_count = $google_params.folders.count
}

# Проверим наличие заданных каталогов. (вероятно лучше перенести в проверку конфига)
New-Item -ItemType Directory -Path $def_paths.progress -Force > $null
New-Item -ItemType Directory -Path $def_paths.finished -Force > $null

# Перебираем найденные раздачи и бекапим их.
Write-Host ('[backuper] Начинаем перебирать раздачи.')
foreach ( $torrent in $torrents_list ) {
    # Ид раздачи
    $torrents_id = $torrent.state
    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrents_id $folder_sep

    # Если подключено несколько гугл-акков, по одному пути, вычисляем номер акка
    $order = Get-GoogleNum $disk_id $google_params.accounts_count

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $order.account - 1
    }

    $google_path = $google_params.folders[$folder_pointer]
    $google_name = ( '{0}({1})' -f $google_path, $order.account )

    $zip_name = $google_path + $disk_path + $torrents_id + '_' + $torrent.hash.ToLower() + '.7z'

    if ( -not ( Test-Path -Path $zip_name ) ) {
        $tmp_zip_name = ( $def_paths.progress + $folder_sep + $torrents_id + '_' + $torrent.hash.ToLower() + '.7z' )

        Write-Host ( 'Архивируем ' + $torrents_id + ', ' + (Get-BaseSize $torrent.size) + ', ' + $torrent.name + ' на диск ' + $google_name ) -ForegroundColor Green
        If ( Test-Path -path $tmp_zip_name ) {
            Write-Host 'Похоже, такой архив уже пишется в параллельной сессии. Пропускаем'
            continue
        }
        else {
            Start-Pause
            # для Unix нужно экранировать кавычки и пробелы.
            if ( $os -eq 'linux' ) { $torrent.content_path = $torrent.content_path.replace('"','\"') }

            # Начинаем архивацию файла
            $compression = Get-Compression $torrent_id $backuper
            Write-Host 'Архивация начата.'
            if ( $backuper.h7z ) {
                & $backuper.p7z a $tmp_zip_name $torrent.content_path "-p$pswd" "-mx$compression" ("-mmt" + $backuper.cores) -mhe=on -sccUTF-8 -bb0 > $null
            } else {
                & $backuper.p7z a $tmp_zip_name $torrent.content_path "-p$pswd" "-mx$compression" ("-mmt" + $backuper.cores) -mhe=on -sccUTF-8 -bb0
            }

            # Считаем результаты архивации
            $zip_size = (Get-Item $tmp_zip_name).Length

            # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
            $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name

            # Если за последние 24ч было отправлено более квоты, то ждём
            while ( $today_size -gt $lv_750gb ) {
                Write-Host ( 'Трафик за прошедшие 24ч по диску ' + $google_name + ' уже ' + (Get-BaseSize $today_size ) )
                Write-Host ( 'Подождём часик чтобы не выйти за лимит ' + (Get-BaseSize $lv_750gb ) + ' (сообщение будет повторяться пока не вернёмся в лимит).' )
                Start-Sleep -Seconds (60 * 60 )

                $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name
                Start-Pause
            }

            if ( $PSVersionTable.OS.ToLower() -contains 'windows') {
                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).Free
                while ( $zip_size -gt ( $fs - 10000000 ) ) {
                    Write-Host ( "Мало места на диске кэша Google ($drive_fs$drive_separator), подождём пока станет больше чем " + ([int]($zip_size / 1024 / 1024)).ToString() + ' Мб')
                    Start-Sleep -Seconds 600
                    $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
                }
            }

            Write-Host ( ( Get-BaseSize $today_size ) + ' пока ещё меньше чем лимит ' + ( Get-BaseSize $lv_750gb ) + ', продолжаем!' )
            try {
                if ( Test-Path -Path $zip_name ) {
                    Write-Host 'Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
                } else {
                    Write-Host 'Перемещаем архив на гугл-диск...'
                    New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force > $null

                    Move-Item -path $tmp_zip_name -destination ( $zip_name ) -Force -ErrorAction Stop
                    Write-Host 'Готово.'

                    # После умпешного переноса архива записываем затраченный трафик
                    Get-TodayTraffic $uploads_all $zip_size $google_name > $null
                }
            }
            catch {
                Write-Host 'Не удалось отправить файл на гугл-диск'
                Pause
            }
        }
    }
    Remove-ClientTorrent $torrent_id $torrent.hash $torrent.category

    $proc_size += $torrent.size
    $text = 'Обработано раздач {0} ({1}) из {2} ({3})'
    Write-Host ( $text -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan

    Start-Pause
    Start-Stopping
}
# end foreach
