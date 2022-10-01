. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

$os, $drive_separator = Get-OsParams

Start-Pause
Clear-Host

if ( $args.count -eq 0 ) {
    $dones = Get-Archives $google_folders
}

# Очищаем пустые папки в папке загрузок
Clear-EmptyFolders $store_path

Write-Output 'Авторизуемся в клиенте..'
$sid = Initialize-Client

# получаем список раздач из клиента
Write-Output 'Получаем список раздач из клиента..'
$torrents_list = Get-ClientTorrents $client_url $sid $args

if ( $torrents_list -eq $null ) {
    Write-Output ( 'Не удалось получить раздачи!' )
    Exit
}

# по каждой раздаче получаем коммент, чтобы достать из него номер топика
Write-Output ( 'Получаем номера топиков по раздачам..' )
$torrents_list = Get-TopicIDs $torrents_list
Write-Output ( '..получено раздач: {0}.' -f $torrents_list.count )

# отбросим раздачи, для которых уже есть архив с тем же хэшем
if ( $args.count -eq 0 ) {
    Write-Output 'Пропускаем уже заархивированные раздачи..'
    $was = $torrents_list.count
    $torrents_list = Get-Required $torrents_list $dones

    if ( $was -ne $torrents_list.count ) {
        Write-Output( '..пропущено раздач: {0}.' -f ($was - $torrents_list.count) )
    }
}

$proc_size = 0
$proc_cnt = 0
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true
Write-Output ( 'Объём новых раздач ({0} шт) {1}.' -f $sum_cnt, (Get-FileSize $sum_size) )
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

# Костыль, для неполного конфига.
if ( $tmp_drive_max -eq $null ) { $tmp_drive_max = 100 * [math]::Pow( 1024, 3) }

$archived_folder_path = $tmp_drive + $drive_separator + 'finished'
# Перебираем найденные раздачи и бекапим их.
foreach ( $torrent in $torrents_list ) {
    # Проверка на переполнение диска архивами.
    while ( $true ) {
        $folder_size = Get-FolderSize $archived_folder_path
        if ( !(Compare-MaxFolderSize $folder_size $tmp_drive_max) ) {
            break
        }
        $text = '{2} Занятый объём диска {0} больше допустимого {1}. Подождём пока освободится.'
        Write-Host ($text -f $archived_folder_path, (Get-FileSize $tmp_drive_max), (Get-Date -Format t) )
        Start-Sleep -Seconds 60
    }

    # Ид раздачи
    $torrent_id = $torrent.state
    $torrent_hash = $torrent.hash.ToLower()

    # Имя арихва.
    $zip_name = $torrent_id.ToString() + '_' + $torrent.hash.ToLower() + '.7z'
    # для Unix нужно экранировать кавычки и пробелы.
    if ( $os -eq 'linux' ) {$torrent.content_path = $torrent.content_path.replace('"','\"') }

    # Полный путь хранения обрабатываемого архива и архива, который готов к заливке.
    $zip_path_progress = $tmp_drive + $drive_separator + $zip_name
    $zip_path_finished = $archived_folder_path + $drive_separator + $zip_name

    Start-Pause
    Write-Host ''
    Write-Host ('Архивируем {0}, {1} ({2})' -f $torrent_id, $torrent.name, (Get-FileSize $torrent.size) ) -ForegroundColor Blue
    # Проверяем, что архив для такой раздачи ещё не создан.
    if ( !( Test-Path -Path $zip_path_finished ) ) {
        $compression = Get-Compression $torrent_id
        # Начинаем архивацию файла
        & $7z_path a $zip_path_progress $torrent.content_path "-p$pswd" "-mx$compression" "-mmt$cores" -mhe=on -sccUTF-8 -bb0
        # Считаем результаты архивации
        $zip_size = (Get-Item $zip_path_progress).Length

        try {
            if ( Test-Path -Path $zip_path_finished ) {
                Remove-Item $zip_path_finished | Out-Null
            }
            Write-Output ( 'Перемещаем {0} в папку {1}..' -f  $zip_name, $archived_folder_path )
            New-Item -ItemType Directory -Path $archived_folder_path -Force | Out-Null
            Move-Item -path $zip_path_progress -destination ( $zip_path_finished ) -Force -ErrorAction Stop
            Write-Output '..готово.'
        }
        catch {
            Write-Output 'Не удалось переместить архив.'
            Pause
        }
    } else {
        Write-Host '..раздача уже имеет архив, пропускаем.'
    }

    $proc_size += $torrent.size
    Write-Output ( 'Обработано раздач {0} ({1}) из {2} ({3})' -f ++$proc_cnt, (Get-FileSize $proc_size), $sum_cnt, (Get-FileSize $sum_size) )
    Start-Stopping
    Start-Pause
}
# end foreach
