If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}

. "$PSScriptRoot\RT_functions.ps1"

If ( -not( Sync-Settings ) ) { Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

if ( $PSVersionTable.OS.ToLower().contains('windows')) { $drive_separator = ':\' } else { $drive_separator = '/' }

Clear-Host

# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024
$upload_log_file = "$PSScriptRoot\config\uploads_all.xml"

if ( $args.count -eq 0 ) {
    Write-Output 'Смотрим, что уже заархивировано..'
    $dones = Get-Archives $google_folders
}
# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | % { 
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Host ( 'Для диска ' + $_.key + ' выгружено: ' + ( Convert-Size $temp_size) + ' Гб (' + $temp_size + ' Б).' )
}

Write-Output 'Авторизуемся в клиенте..'
$sid = Initialize-Client

# получаем список раздач из клиента
if ( $args.Count -eq 0) {
    Write-Output 'Получаем список раздач из клиента..'
    $torrents_list = Get-ClientTorrents $client_url $sid $args
}
else {
    Write-Output 'Получаем общую информацию о раздаче из клиента..'
    $torrents_list = Get-ClientTorrents $client_url $sid $args
}


if ( $torrents_list -eq $null ) {
    Write-Output ( 'Не удалось получить раздачи.' )
    Exit
}
Write-Output ( 'Получено ' + $torrents_list.count + ' раздач.')

# по каждой раздаче получаем коммент, чтобы достать из него номер топика
Write-Output ( 'Получаем номера топиков по раздачам..' )
$torrents_list = Get-TopicIDs $torrents_list

# отбросим раздачи, для которых уже есть архив с тем же хэшем
if ( $args.count -eq 0 ) {
    Write-Output 'Пропускаем уже заархивированные раздачи..'
    $was = $torrents_list.count
    $torrents_list = Get-Required $torrents_list $dones
    if ( $was -ne $torrents_list.count ) { Write-Output( 'Пропущено ' + ( $was - $torrents_list.count ) + ' раздач.') }
}

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true
Write-Output ( 'Объём новых раздач (' + $sum_cnt + ' шт) ' + ( Convert-Size $sum_size) + ' Гб (' + $sum_size + ' Б).' )

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

# Перебираем найденные раздачи и бекапим их.
foreach ( $torrent in $torrents_list ) {

    $google_folder = $google_folders[$folder_pointer]
    $folder_pointer = [math]::IEEERemainder( ( $folder_pointer + 1 ), $google_folders.count )

    # Собираем имя и путь хранения архива раздачи.
    $folder_name = '\ArchRuT_' + ( 300000 * [math]::Truncate(( $torrent.state - 1 ) / 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $torrent.state - 1 ) / 300000) + 1 ) + '\'
    $zip_name = $google_folder + $folder_name + $torrent.state + '_' + $torrent.hash.ToLower() + '.7z'
    # для Unix нужно экранировать кавычки и пробелы"
    if ( -not( $PSVersionTable.OS.ToLower().contains('windows')) ) {$torrent.content_path = $torrent.content_path.replace('"','\"') }

    if ( -not ( test-path -Path $zip_name ) ) {
        $tmp_zip_name = ( $tmp_drive + $drive_separator + $torrent.state + '_' + $torrent.hash + '.7z' )

        Write-Host ( 'Архивируем ' + $torrent.state + ', ' + $torrent.name + ' на диск ' + $google_folder ) -ForegroundColor Blue
        If ( Test-Path -path $tmp_zip_name ) {
            Write-Output 'Похоже, такой архив уже пишется в параллельной сессии. Пропускаем'
            continue
        }
        else {
            $uploads_all = Get-StoredUploads
            # Начинаем архивацию файла
            $compression = Get-Compression $sections_compression $default_compression $torent
            Write-Host ''
                & $7z_path a $tmp_zip_name $torrent.content_path "-p20RuTracker.ORG22" "-mx$compression" "-mmt$cores" -mhe=on -sccUTF-8 -bb0

            # Считаем результаты архивации
            $zip_size = (Get-Item $tmp_zip_name).Length

            # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
            $size_grp = Get-TodayTraffic $uploads_all 0 $google_folder
            $today_size = $size_grp[0]
            $uploads_all = $size_grp[1]

            # Если за последние 24ч было отправлено более квоты, то ждём
            while ( $today_size -gt $lv_750gb ) {
                Write-Output ( 'Трафик за прошедшие 24ч по диску ' + $google_folder + ' уже ' + (Convert-Size $today_size ) + ' Гб' )
                Write-Output ( 'Подождём часик чтобы не выйти за лимит' + (Convert-Size $lv_750gb ) + ' Гб. (сообщение будет повторяться пока не вернёмся в лимит)' )
                Start-Sleep -Seconds (60 * 60 )

                $size_grp = Get-TodayTraffic $uploads_all 0 $google_folder
                $today_size = $size_grp[0]
                $uploads_all = $size_grp[1]
            }

            if ( $PSVersionTable.OS.ToLower() -contains 'windows') {
                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).Free
                while ( $zip_size -gt ( $fs - 10000000 ) ) {
                    Write-Output ( "Мало места на диске кэша Google ($drive_fs$drive_separator), подождём пока станет больше чем " + ([int]($zip_size / 1024 / 1024)).ToString() + ' Мб')
                    Start-Sleep -Seconds 600
                    $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
                }
            }

            Write-Output ( ( Convert-Size $today_size ) + ' Гб пока ещё меньше чем лимит ' + ( Convert-Size $lv_750gb ) + ' Гб, продолжаем' )
            try {

                Write-Output 'Перемещаем архив на гугл-диск...'
                Move-Item -path $tmp_zip_name -destination ( $zip_name ) -Force -ErrorAction Stop
                Write-Output 'Готово.'

                # После переноса архива записываем затраченный трафик
                Get-TodayTraffic $uploads_all $zip_size $google_folder

            }
            catch {
                Write-Output 'Не удалось отправить файл на гугл-диск'
                Pause
            }
        }
    }
    if ( $delete_processed -eq 1 ) {
        try {
            Write-Output ( 'Удаляем из клиента раздачу ' + $torrent.state )
            $reqdata = 'hashes=' + $torrent.hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST > $nul
        }
        catch { Write-Output 'Почему-то не получилось удалить раздачу ' + $torrent.state }
    }

    $proc_cnt++
    $proc_size += $torrent.size
    Write-Output ( 'Обработано ' + $proc_cnt + ' раздач (' + `
        (Convert-Size $proc_size ) + ' Гб) из ' +`
        $sum_cnt + ' (' + (Convert-Size $sum_size 1000 ) + ' Гб)' )
    Start-Stopping
}
