. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Start-Stopping

Write-Host '[uploader] Начинаем процесс выгрузки архивов в гугл.'
# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
Show-StoredUploads $uploads_all

# Если используемых акков >1 и передан параметр с номером, то используем балансировку.
if ( $args.count -ne 0 -and $google_params.accounts_count -gt 1 ) {
    $uploader_num = $args[0]

    if ( $uploader_num -gt $google_params.uploaders_count) {
        Write-Host ( '[balance] Неверный номер сервиса "{0}". Акканутов подключено {1}. Прерываем.' -f $uploader_num, $google_params.uploaders_count ) -ForegroundColor Red
        Exit
    }
    Write-Host ( '[balance] Включена многопоточная выгрузка. Номер сервиса: {0}' -f $uploader_num ) -ForegroundColor Yellow
}

# Ищем список архивов, которые нужно перенести
$zip_list = Get-ChildItem $def_paths.finished -Filter '*.7z' | Sort-Object $OS.sizeField

$proc_cnt = 0
$proc_size = 0
$sum_cnt = $zip_list.count
$sum_size = ( $zip_list | Measure-Object $OS.sizeField -Sum ).Sum
Write-Host ( '[uploader] Найдено архивов: {0} ({1}), требующих переноса на гугл-диск, начинаем!' -f $sum_cnt, (Get-BaseSize $sum_size) )
if ( $sum_cnt -eq 0 ) { Exit }

Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 10)

# Перебираем архивы.
foreach ( $zip in $zip_list ) {
    Start-Pause

    $torrent_id, $torrent_hash = ( $zip.Name.Split('.')[0] ).Split('_')
    $zip_size = $zip.($OS.sizeField)

    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id

    # Вычисляем выгружаемый аккаунт и номер процесса выгрузки.
    $order = Get-GoogleNum $disk_id -Accounts $google_params.accounts_count -Uploaders $google_params.uploaders_count
    if ( $uploader_num -And $uploader_num -ne $order.upload ) {
        Write-Host ( '[skip] {0} для другого процесса [{1}].' -f $torrent_id, $order.upload ) -ForegroundColor Yellow
        Continue
    }

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $order.account - 1
    }
    $google_path = $google_params.folders[$folder_pointer]
    $google_name = ( '{0}({1})' -f $google_path, $order.account )

    $zip_current_path = $def_paths.finished + $OS.fsep + $zip.Name
    $zip_google_path  = $google_path + $disk_path + $zip.Name

    Write-Host ''
    Write-Host ( '[torrent] Раздача: id={0} ({4}), disk=[{1}], path={2} {3}' -f $torrent_id, $disk_id, $google_name, $disk_name, (Get-BaseSize $zip_size) )
    try {
        if ( $uploader.validate ) {
            Write-Host '[check] Начинаем проверку целостности архива перед отправкой в гугл.'
            $start_measure = Get-Date

            if ( $backuper.h7z ) {
                & $backuper.p7z t $zip_current_path "-p$pswd" > $null
            } else {
                & $backuper.p7z t $zip_current_path "-p$pswd"
            }

            if ( $LastExitCode -ne 0 ) {
                throw ( '[check] Архив не прошёл проверку, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
            }

            $time_valid = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
            Write-Host ( '[check] Проверка завершена за {0} сек.' -f $time_valid )
        }

        # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
        $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name

        # Если за последние 24ч, по выбранному аккаунту, было отправлено более квоты, то ждём.
        while ( $today_size -gt $lv_750gb ) {
            Write-Host ( '[limit][{0}] Трафик гугл-аккаунта {1} за прошедшие 24ч уже {2}' -f (Get-Date -Format t), $google_name, (Get-BaseSize $today_size ) )
            Write-Host ( '[limit] Подождём часик чтобы не выйти за лимит {0} (сообщение будет повторяться пока не вернёмся в лимит).' -f (Get-BaseSize $lv_750gb ) )
            Start-Sleep -Seconds ( 60 * 60 )

            Start-Pause
            $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name
        }
        Write-Host ( '[limit] {0} {1} меньше чем лимит {2}, продолжаем!' -f $google_name, (Get-BaseSize $today_size), (Get-BaseSize $lv_750gb) )

        # Проверка на переполнение каталога с архивами.
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
                Move-Item -path $zip_current_path -destination ( $zip_google_path ) -Force -ErrorAction Stop
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
            Pause
        }
    } catch {
        Remove-Item $zip_current_path
        Write-Host $Error[0] -ForegroundColor Red
    }

    $proc_size += $zip_size
    Write-Host ( '[uploader] Обработано раздач {0} ({1}) из {2} ({3})' -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size) )

    Start-Pause
    Start-Stopping
}
# end foreach
