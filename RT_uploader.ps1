. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Clear-Host

Write-Host '[uploader] Начинаем процесс выгрузки архивов в гугл.'
# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | Sort-Object -Property Key | % {
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Host ( 'Для диска {0} выгружено: {1}' -f $_.key, ( Get-FileSize $temp_size) )
}

$os, $folder_sep = Get-OsParams

# ПЕРЕНЕСТИ В ВАЛИДАЦИЮ
# Проверяем наличие нового параметра в конфиге
if ( $google_params.accounts_count -eq $null -Or $google_params.accounts_count -gt 5 ) {
    $google_params.accounts_count = 1
}
# Если подключённых дисков больше одного, то кол-во акков = колву дисков
if ( $google_params.folders.count -gt 1 ) {
    $google_params.accounts_count = $google_params.folders.count
}

# Если используемых акков >1 и передан параметр с номером, то используем балансировку.
if ( $args.count -ne 0 -and $google_params.accounts_count -gt 1 ) {
    $google_load_num = $args[0]
    if ( $google_load_num -gt $google_params.accounts_count) {
        Write-Host ( '[uploader] Неверный параметр балансировки "{0}". Акканутов подключено {1}. Прерываем.' -f $google_load_num, $google_params.accounts_count ) -ForegroundColor Red
        Exit
    }
    Write-Host ( '[uploader] Включена балансировка выгрузки. Выбранный аккаунт: {0}' -f $google_load_num ) -ForegroundColor Yellow
}

# Ищем список архивов, которые нужно перенести
$zip_list = Get-ChildItem $arch_params.finished -Recurse

$proc_cnt = 0
$proc_size = 0
$sum_cnt = $zip_list.count
$sum_size = ( $zip_list | Measure-Object -sum size ).Sum

Write-Host ( '[uploader] Найдено архивов: {0} ({1}), требующих переноса на гугл-диск, начинаем!' -f $sum_cnt, (Get-FileSize $sum_size) )
if ( $sum_cnt -eq 0 ) {Exit}

Write-Host '[uploader] Авторизуемся в клиенте.'
try {
    $sid = Initialize-Client
} catch {
    Write-Host ( 'Авторизация не удалась. {0}' -f $Error[0] ) -ForegroundColor Red
    Exit
}

# Перебираем архивы.
foreach ( $zip in $zip_list ) {
    Start-Pause
    if ( $zip.Size -eq 32 ) {
        Remove-Item $zip.FullName
        Continue
    }

    $torrent_id, $torrent_hash = ( $zip.Name.Split('.')[0] ).Split('_')
    $torrent = Get-ClientTorrents $client_url $sid @( $torrent_hash )

    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id $folder_sep

    # Если подключено несколько гугл-акков, вычисляем номер акка для раздачи.
    $google_num = Get-GoogleNum $disk_id $google_params.accounts_count

    if ( $google_load_num -And $google_load_num -ne $google_num ) {
        Write-Host ( '[skip] Пропущена раздача {0} для аккаунта {1}.' -f $torrent_id, $google_num ) -ForegroundColor Yellow
        Continue
    }

    Write-Host ''
    Write-Host ( '[uploader] Начинаем перенос раздачи {0} ({1}), {2}' -f $torrent_id, (Get-FileSize $zip.Size), $torrent.name ) -ForegroundColor Green

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $google_num - 1
    }
    $google_path = $google_params.folders[$folder_pointer]
    $google_name = $google_path + "($google_num)"

    $zip_current_path = $arch_params.finished + $folder_sep + $zip.Name
    $zip_google_path = $google_path + $disk_path + $zip.Name

    $delete_torrent = $true
    $text = '[uploader] Раздача: id={0}, disk=[{1}] {2}, path={3},'
    Write-Host ( $text -f $torrent_id, $disk_id, $disk_name, $google_name )
    try {
        $zip_test = Test-PathTimer $zip_google_path
        Write-Host ( '[check][{0}] Проверка в гугле заняла {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
        if ( $zip_test.result ) {
            Dismount-ClientTorrent $torrent_id $torrent_hash
            throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
        }

        if ( $upload_params.validate ) {
            Write-Host '[uploader] Начинаем проверку архива перед отправкой в гугл.'
            $start_measure = Get-Date
            & $7z_path t $zip_current_path "-p$pswd"
            if ( $LastExitCode -ne 0 ) {
                $delete_torrent = $false
                throw ( 'Архив не прошёл проверку целостности, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
            }

            # Считаем результаты архивации
            $time_valid = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
            Write-Host ( '[check] Проверка целостности завершена за {0} сек.' -f $time_valid )
        }

        # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
        $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name

        # Если за последние 24ч, по выбранному аккаунту, было отправлено более квоты, то ждём.
        while ( $today_size -gt $lv_750gb ) {
            Write-Host ( '[limit][{0}] Трафик за прошедшие 24ч по диску {1} уже {2}' -f (Get-Date -Format t), $google_name, (Get-FileSize $today_size ) )
            Write-Host ( '[limit] Подождём часик чтобы не выйти за лимит {0} (сообщение будет повторяться пока не вернёмся в лимит).' -f (Get-FileSize $lv_750gb ) )
            Start-Sleep -Seconds ( 60 * 60 )

            Start-Pause
            $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name
        }

        # ХЗ что это делает и зачем оно.
        if ( $PSVersionTable.OS.ToLower() -contains 'windows') {
            $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).Free
            while ( $zip.Size -gt ( $fs - 10000000 ) ) {
                Write-Host ( "Мало места на диске кэша Google ($drive_fs$folder_sep), подождём пока станет больше чем " + ([int]($zip.Size / 1024 / 1024)).ToString() + ' Мб')
                Start-Sleep -Seconds 600
                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
            }
        }

        Write-Host ( '{0} {1} меньше чем лимит {2}, продолжаем!' -f $google_name, (Get-FileSize $today_size), (Get-FileSize $lv_750gb) )
        try {
            $zip_test = Test-PathTimer $zip_google_path
            Write-Host ( '[check][{0}] Проверка в гугле заняла {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
            if ( $zip_test.result ) {
                Dismount-ClientTorrent $torrent_id $torrent_hash
                throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
            }

            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force | Out-Null

            $move_sec = [math]::Round( (Measure-Command {
                Move-Item -path $zip_current_path -destination ( $zip_google_path ) -Force -ErrorAction Stop
            }).TotalSeconds, 1 )
            if ( !$move_sec ) {$move_sec = 0.1}

            $speed_move = (Get-FileSize ($torrent.size / $move_sec) -SI speed_2)
            Write-Host ( '[uploader] Готово! Завершено за {0} минут, средняя скорость {1}' -f [math]::Round($move_sec/60, 1) , $speed_move )
            Dismount-ClientTorrent $torrent_id $torrent_hash

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip.Size $google_name | Out-Null
        }
        catch {
            $delete_torrent = $false
            Write-Host 'Не удалось отправить файл на гугл-диск'
            Pause
        }
    } catch {
        # Remove-Item $zip_current_path
        Write-Host $Error[0] -ForegroundColor Red
    }

    $proc_size += $torrent.size
    Write-Output ( 'Обработано раздач {0} ({1}) из {2} ({3})' -f ++$proc_cnt, (Get-FileSize $proc_size), $sum_cnt, (Get-FileSize $sum_size) )

    Start-Stopping
    Start-Pause
}
# end foreach
