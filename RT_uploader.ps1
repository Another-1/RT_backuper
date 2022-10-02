. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Clear-Host

# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
$uploads_all.GetEnumerator() | % {
    $temp_size = ( $_.value.values | Measure-Object -sum ).Sum
    Write-Host ( 'Для диска {0} выгружено: {1}' -f $_.key, ( Get-FileSize $temp_size) )
}

$os, $drive_separator = Get-OsParams
$archived_folder_path = $tmp_drive + $drive_separator + 'finished'

# Проверяем наличие нового параметра в конфиге
if ( $google_accounts_count -eq $null -Or $google_accounts_count -gt 5 ) {
    $google_accounts_count = 1
}
# Если подключённых дисков больше одного, то кол-во акков = колву дисков
if ( $google_folders.count -gt 1 ) {
    $google_accounts_count = $google_folders.count
}

Write-Host 'Авторизуемся в клиенте..'
$sid = Initialize-Client
# Ищем список архивов, которые нужно перенести
$zip_list = Get-ChildItem -Recurse $archived_folder_path

$hashes = $zip_list | ForEach-Object { ( $_.Name.Split('.')[0] ).Split('_')[1]}
$torrents = Get-ClientTorrents $client_url $sid $hashes

$proc_cnt = 0
$proc_size = 0
$sum_cnt = $zip_list.count
$sum_size = ( $zip_list | Measure-Object -sum size ).Sum

# Если используемых акков >1 и передан параметр, то используем фильтрацию
if ( $args.count -ne 0 -and $google_accounts_count -gt 1 ) {
    $google_load_num = $args[0]
    if ( $google_load_num -gt $google_accounts_count) {
        Write-Host ( 'Неверный параметр балансировки "{0}". Акканутов подключено {1}. Прерываем.' -f $google_load_num, $google_accounts_count ) -ForegroundColor Red
        Exit
    }
    Write-Host ( 'Включена балансировка выгрузки. Выбранный аккаунт: {0}' -f $google_load_num ) -ForegroundColor Yellow
}

Write-Host ( 'Найдено архивов: {0} ({1}), требующих переноса на гугл-диск, начинаем!' -f $sum_cnt, (Get-FileSize $sum_size) )
if ( $sum_cnt -eq 0 ) {Exit}
# Перебираем архивы.
foreach ( $zip in $zip_list ) {
    Start-Pause

    $torrent_id, $torrent_hash = ( $zip.Name.Split('.')[0] ).Split('_')
    $torrent = $torrents | Where-Object { $_.hash -eq $torrent_hash }

    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id $drive_separator

    # Если подключено несколько гугл-акков, вычисляем номер акка
    $google_num = Get-GoogleNum $disk_id $google_accounts_count

    if ( $google_load_num -ne $null -and $google_load_num -ne $google_num ) {
        Write-Host ( 'Пропущена раздача {0} для аккаунта {1}.' -f $torrent_id, $google_num ) -ForegroundColor Yellow
        Continue
    }

    Write-Host ''
    Write-Host ( 'Начинаем перенос раздачи {0}, {1} ({2})' -f $torrent_id, $torrent.name, (Get-FileSize $zip.Size) ) -ForegroundColor Green

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_folders.count -gt 1 ) {
        $folder_pointer = $google_num - 1
    }
    $google_folder_path = $google_folders[$folder_pointer]
    $google_folder = $google_folder_path + "($google_num)"

    $zip_current_path = $archived_folder_path + $drive_separator + $zip.Name
    $zip_google_path = $google_folder_path + $disk_path + $zip.Name

    $delete_torrent = $true
    $text = 'Параметры раздачи id={0}, disk={1}, path={2}, folder={3}'
    Write-Host ( $text -f $torrent_id, $disk_id, $google_folder, $disk_name )
    try {
        if ( Test-Path -Path $zip_google_path ) {
            throw 'Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
        }

        & $7z_path t $zip_current_path "-p$pswd" | Out-Null
        if ( $LastExitCode -ne 0 ) {
            $delete_torrent = $false
            throw ( 'Архив не прошёл проверку целостности, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
        }

        # Перед переносом проверяем доступный трафик. 0 для получения актуальных данных.
        $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_folder

        # Если за последние 24ч, по выбранному аккаунту, было отправлено более квоты, то ждём.
        while ( $today_size -gt $lv_750gb ) {
            Write-Host ( 'Трафик за прошедшие 24ч по диску {0} уже {1}' -f $google_folder, (Get-FileSize $today_size ) )
            Write-Host ( 'Подождём часик чтобы не выйти за лимит {0} (сообщение будет повторяться пока не вернёмся в лимит).' -f (Get-FileSize $lv_750gb ) )
            Start-Sleep -Seconds (60 * 60 )

            Start-Pause
            $today_size, $uploads_all = Get-TodayTraffic $uploads_all 0 $google_folder
        }

        # ХЗ что это делает и зачем оно.
        if ( $PSVersionTable.OS.ToLower() -contains 'windows') {
            $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).Free
            while ( $zip.Size -gt ( $fs - 10000000 ) ) {
                Write-Host ( "Мало места на диске кэша Google ($drive_fs$drive_separator), подождём пока станет больше чем " + ([int]($zip.Size / 1024 / 1024)).ToString() + ' Мб')
                Start-Sleep -Seconds 600
                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
            }
        }

        Write-Host ( '{0} {1} меньше чем лимит {2}, продолжаем!' -f $google_folder, (Get-FileSize $today_size), (Get-FileSize $lv_750gb) )
        try {
            if ( Test-Path -Path $zip_google_path ) {
                throw 'Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
            }

            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_folder_path + $disk_path) -Force | Out-Null

            Move-Item -path $zip_current_path -destination ( $zip_google_path ) -Force -ErrorAction Stop
            Write-Host 'Готово!'

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip.Size $google_folder | Out-Null
        }
        catch {
            $delete_torrent = $false
            Write-Host 'Не удалось отправить файл на гугл-диск'
            Pause
        }
    } catch {
        Remove-Item $zip_current_path
        Write-Host $Error[0] -ForegroundColor Red
    }

    # Попытка удалить раздачу из клиента
    if ( $delete_torrent ) {
        Delete-Torrent $torrent_id $torrent_hash $torrent.category
    }

    $proc_size += $torrent.size
    Write-Output ( 'Обработано раздач {0} ({1}) из {2} ({3})' -f ++$proc_cnt, (Get-FileSize $proc_size), $sum_cnt, (Get-FileSize $sum_size) )

    Start-Stopping
    Start-Pause
}
# end foreach
