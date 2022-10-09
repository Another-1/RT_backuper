. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Clear-Host
Start-Pause
Start-Stopping

Write-Host '[uploader] Начинаем процесс выгрузки архивов в гугл.'
# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | Sort-Object -Property Key | % {
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Host ( 'Для диска {0} выгружено: {1}' -f $_.key, ( Get-BaseSize $temp_size) )
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
    $uploader_num = $args[0]

    if ( $google_params.uploaders_count -gt $google_params.accounts_count ) {
        $text = '[balance] Неверный набор параметров accounts_count:{0} >= uploaders_count:{1}.' -f $google_params.accounts_count, $google_params.uploaders_count
        Write-Host $text -ForegroundColor Red
        Write-Host 'Параметры скорректированы, но проверьте файл настроек.'
        $google_params.uploaders_count = $google_params.accounts_count
    }

    if ( $uploader_num -gt $google_params.uploaders_count) {
        Write-Host ( '[balance] Неверный параметр балансировки "{0}". Акканутов подключено {1}. Прерываем.' -f $uploader_num, $google_params.uploaders_count ) -ForegroundColor Red
        Exit
    }
    Write-Host ( '[balance] Включена балансировка выгрузки. Выбранный аккаунт: {0}' -f $uploader_num ) -ForegroundColor Yellow
}

# Ищем список архивов, которые нужно перенести
$zip_list = Get-ChildItem $backuper.finished -Filter '*.7z'

$proc_cnt = 0
$proc_size = 0
$sum_cnt = $zip_list.count
$sum_size = ( $zip_list | Measure-Object -sum size ).Sum

Write-Host ( '[uploader] Найдено архивов: {0} ({1}), требующих переноса на гугл-диск, начинаем!' -f $sum_cnt, (Get-BaseSize $sum_size) )
if ( $sum_cnt -eq 0 ) { Exit }

Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 10)
Initialize-Client

# Перебираем архивы.
foreach ( $zip in $zip_list ) {
    Start-Pause
    if ( $zip.Size -eq 32 ) {
        Remove-Item $zip.FullName
        Continue
    }

    $torrent_id, $torrent_hash = ( $zip.Name.Split('.')[0] ).Split('_')

    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id $folder_sep

    # Вычисляем выгружаемый аккаунт и номер процесса выгрузки.
    $order = Get-GoogleNum $disk_id -Accounts $google_params.accounts_count -Uploaders $google_params.uploaders_count
    if ( $uploader_num -And $uploader_num -ne $order.upload ) {
        Write-Host ( '[skip] Пропущена раздача {0} для другого процесса выгрузки {1}.' -f $torrent_id, $order.upload ) -ForegroundColor Yellow
        Continue
    }

    $torrent = Import-TorrentProperties $zip.Name $torrent_hash
    Write-Host ''
    Write-Host ( '[uploader] Начинаем перенос раздачи {0} ({1}), {2}' -f $torrent_id, (Get-BaseSize $zip.Size), $torrent.name ) -ForegroundColor Green

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $order.account - 1
    }
    $google_path = $google_params.folders[$folder_pointer]
    $google_name = ( '{0}({1})' -f $google_path, $order.account )

    $zip_current_path = $backuper.finished + $folder_sep + $zip.Name
    $zip_google_path  = $google_path + $disk_path + $zip.Name

    $text = '[uploader] Раздача: id={0}, disk=[{1}] {2}, path={3},'
    Write-Host ( $text -f $torrent_id, $disk_id, $disk_name, $google_name )
    try {
        if ( $upload_params.validate ) {
            Write-Host '[uploader] Начинаем проверку архива перед отправкой в гугл.'
            $start_measure = Get-Date

            if ( $backuper.h7z ) {
                & $backuper.p7z t $zip_current_path "-p$pswd" > $null
            } else {
                & $backuper.p7z t $zip_current_path "-p$pswd"
            }

            if ( $LastExitCode -ne 0 ) {
                throw ( '[check] Архив не прошёл проверку целостности, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
            }

            # Считаем результаты архивации
            $time_valid = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
            Write-Host ( '[check] Проверка целостности завершена за {0} сек.' -f $time_valid )
        }

        # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
        $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_name

        # Если за последние 24ч, по выбранному аккаунту, было отправлено более квоты, то ждём.
        while ( $today_size -gt $lv_750gb ) {
            Write-Host ( '[limit][{0}] Трафик за прошедшие 24ч по диску {1} уже {2}' -f (Get-Date -Format t), $google_name, (Get-BaseSize $today_size ) )
            Write-Host ( '[limit] Подождём часик чтобы не выйти за лимит {0} (сообщение будет повторяться пока не вернёмся в лимит).' -f (Get-BaseSize $lv_750gb ) )
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

        Write-Host ( '[limit] {0} {1} меньше чем лимит {2}, продолжаем!' -f $google_name, (Get-BaseSize $today_size), (Get-BaseSize $lv_750gb) )
        try {
            Write-Host 'Проверяем наличие архива на гугл-диске...'
            $zip_test = Test-PathTimer $zip_google_path
            Write-Host ( '[check][{0}] Проверка в гугле заняла {1} сек, результат: {2}' -f $disk_name, $zip_test.exec, $zip_test.result )
            if ( $zip_test.result ) {
                Dismount-ClientTorrent $torrent_id $torrent_hash
                throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
            }

            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force > $null

            $move_sec = [math]::Round( (Measure-Command {
                Move-Item -path $zip_current_path -destination ( $zip_google_path ) -Force -ErrorAction Stop
            }).TotalSeconds, 1 )
            if ( !$move_sec ) {$move_sec = 0.1}

            $speed_move = (Get-BaseSize ($zip.Size / $move_sec) -SI speed_2)
            Write-Host ( '[uploader] Готово! Завершено за {0} минут, средняя скорость {1}' -f [math]::Round($move_sec/60, 1) , $speed_move )

            Dismount-ClientTorrent $torrent_id $torrent_hash

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip.Size $google_name > $null
        }
        catch {
            Write-Host '[uploader] Не удалось отправить файл на гугл-диск'
            Pause
        }
    } catch {
        Remove-Item $zip_current_path
        Write-Host $Error[0] -ForegroundColor Red
    }

    $proc_size += $zip.Size
    Write-Output ( '[uploader] Обработано раздач {0} ({1}) из {2} ({3})' -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size) )

    Start-Pause
    Start-Stopping
}
# end foreach
