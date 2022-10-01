. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }


Start-Pause
Clear-Host

$os, $drive_separator = Get-OsParams
# лимит закачки на один гугл-аккаунт в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

# Получаем данные об объёме выгрузки.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | % {
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Output ( 'Для диска ' + $_.key + ' выгружено: ' + ( Get-FileSize $temp_size) + ' (' + $temp_size + ' B).' )
}

if ( $args.count -eq 0 ) {
    $dones = Get-Archives $google_folders
}

$test_key = '5643903_9a994b28029318367418c680f971c20505aeaedb'

Write-Output 'Авторизуемся в клиенте..'
$sid = Initialize-Client

# получаем список раздач из клиента
Write-Output 'Получаем список раздач из клиента..'
$torrents_list = Get-ClientTorrents $client_url $sid $args

if ( $torrents_list -eq $null ) {
    Write-Output ( 'Не удалось получить раздачи.' )
    Exit
}
$torrents_list

# по каждой раздаче получаем коммент, чтобы достать из него номер топика
Write-Output ( 'Получаем номера топиков по раздачам..' )
$torrents_list = Get-TopicIDs $torrents_list
Write-Output ( 'Получено {0} раздач.' -f $torrents_list.count )

Exit
# отбросим раздачи, для которых уже есть архив с тем же хэшем
if ( $args.count -eq 0 ) {
    Write-Output 'Пропускаем уже заархивированные раздачи..'
    $was = $torrents_list.count
    $torrents_list = Get-Required $torrents_list $dones

    if ( $was -ne $torrents_list.count ) {
        Write-Output( 'Пропущено {0} раздач.' -f ($was - $torrents_list.count) )
    }
}

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true
Write-Output ( 'Объём новых раздач (' + $sum_cnt + ' шт) ' + ( Get-FileSize $sum_size) + ' (' + $sum_size + ' B).' )

if ( $args.count -eq 0 ) {
    # проверяем, что никакие раздачи не пересекаются по именам файлов (если файл один) или каталогов (если файлов много), чтобы не заархивировать не то
    Write-Output ( 'Проверяем уникальность путей сохранения раздач..' )

    foreach ( $torrent in $torrents_list ) {
        if ( $used_locs.keys -contains $torrent.content_path ) {
            Write-Output ( 'Несколько раздач хранятся по пути "' + $torrent.content_path + '" !')
            Write-Output ( 'Нажмите любую клавищу, исправьте и начните заново !')
            $ok = $false
        }
        else { $used_locs += $torrent.content_path }
    }
    If ( $ok -eq $false) {
        pause
        Exit
    }
}
if ( $args.Count -eq 0 ) { $folder_pointer = 0 }
else { $folder_pointer = Get-Random -InputObject ( 0..($google_folders.count-1) )}

# Проверяем наличие нового параметра в конфиге
if ( $google_folders_count -eq $null -Or $google_folders_count -gt 5 ) {
    $google_folders_count = 1
}

# Перебираем найденные раздачи и бекапим их.
foreach ( $torrent in $torrents_list ) {
    $uploads_all = Get-StoredUploads $uploads_all

    # Ид раздачи
    $torrents_id = $torrent.state
    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrents_id '\'

    # Если подключено несколько гугл-акков, по одному пути, вычисляем номер акка
    $google_num = Get-GoogleNum $disk_id $google_folders_count
    $google_folder_path = $google_folders[$folder_pointer]
    $folder_pointer = [math]::IEEERemainder( ( $folder_pointer + 1 ), $google_folders.count )
    $google_folder = $google_folder_path + "($google_num)"

    $zip_name = $google_folder_path + $disk_path + $torrents_id + '_' + $torrent.hash.ToLower() + '.7z'
    # для Unix нужно экранировать кавычки и пробелы"
    if ( -not( $PSVersionTable.OS.ToLower().contains('windows')) ) {$torrent.content_path = $torrent.content_path.replace('"','\"') }

    if ( -not ( Test-Path -Path $zip_name ) ) {
        $tmp_zip_name = ( $tmp_drive + $drive_separator + $torrents_id + '_' + $torrent.hash.ToLower() + '.7z' )

        Write-Host ( 'Архивируем ' + $torrents_id + ', ' + (Get-FileSize $torrent.size) + ', ' + $torrent.name + ' на диск ' + $google_folder ) -ForegroundColor Blue
        If ( Test-Path -path $tmp_zip_name ) {
            Write-Output 'Похоже, такой архив уже пишется в параллельной сессии. Пропускаем'
            continue
        }
        else {
            Start-Pause
            # Начинаем архивацию файла
            $compression = Get-Compression $sections_compression $default_compression $torent
            Write-Host ''
                & $7z_path a $tmp_zip_name $torrent.content_path "-p20RuTracker.ORG22" "-mx$compression" "-mmt$cores" -mhe=on -sccUTF-8 -bb0

            # Считаем результаты архивации
            $zip_size = (Get-Item $tmp_zip_name).Length

            # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
            $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_folder

            # Если за последние 24ч было отправлено более квоты, то ждём
            while ( $today_size -gt $lv_750gb ) {
                Write-Output ( 'Трафик за прошедшие 24ч по диску ' + $google_folder + ' уже ' + (Get-FileSize $today_size ) )
                Write-Output ( 'Подождём часик чтобы не выйти за лимит ' + (Get-FileSize $lv_750gb ) + ' (сообщение будет повторяться пока не вернёмся в лимит).' )
                Start-Sleep -Seconds (60 * 60 )

                $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_folder
                Start-Pause
            }

            if ( $PSVersionTable.OS.ToLower() -contains 'windows') {
                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).Free
                while ( $zip_size -gt ( $fs - 10000000 ) ) {
                    Write-Output ( "Мало места на диске кэша Google ($drive_fs$drive_separator), подождём пока станет больше чем " + ([int]($zip_size / 1024 / 1024)).ToString() + ' Мб')
                    Start-Sleep -Seconds 600
                    $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
                }
            }

            Write-Output ( "$google_folder, " + ( Get-FileSize $today_size ) + ' пока ещё меньше чем лимит ' + ( Get-FileSize $lv_750gb ) + ', продолжаем!' )
            try {
                if ( Test-Path -Path $zip_name ) {
                    Write-Output 'Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
                } else {
                    Write-Output 'Перемещаем архив на гугл-диск...'
                    # Move-Item -path $tmp_zip_name -destination ( $zip_name ) -Force -ErrorAction Stop
                    Write-Output 'Готово.'

                    # После умпешного переноса архива записываем затраченный трафик
                    Get-TodayTraffic $uploads_all $zip_size $google_folder | Out-Null
                }
            }
            catch {
                Write-Output 'Не удалось отправить файл на гугл-диск'
                Pause
            }
        }
    }
    if ( $delete_processed -eq 1 -And $torrent.category -eq $default_category ) {
        try {
            Write-Output ( 'Удаляем из клиента раздачу ' + $torrents_id )
            $reqdata = 'hashes=' + $torrent.hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST > $nul
        }
        catch { Write-Output 'Почему-то не получилось удалить раздачу ' + $torrent.state }
    }

    $proc_cnt++
    $proc_size += $torrent.size
    Write-Output ( 'Обработано раздач ' + $proc_cnt + ' (' + (Get-FileSize $proc_size) + ') из ' + `
        $sum_cnt + ' (' + (Get-FileSize $sum_size) + ')' )
    Start-Stopping
    Start-Pause
}
# end foreach
