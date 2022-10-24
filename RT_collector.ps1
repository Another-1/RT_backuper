. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

# Аргументов 0, всё вводим по подсказкам.
If ($args.Count -eq 0 ) {
    $choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()
    $min_id = ( Read-Host -Prompt 'Минимальный ID ( 0 если не нужно проверять ID)' )
    if ( $min_id ) {
        $max_id = ( Read-Host -Prompt 'Максимальный ID' )
    }
    $min_sid = ( Read-Host -Prompt 'Минимальное количество сидов ( 0 если не нужно проверять сидов)' )
}
# Аргумент 1, т.е. задан раздел, все остальное - дефолт.
elseif ($args.count -eq 1) {
    $choice = $args[0].ToString()
    $min_id = 0
}
# Аргументов три, раздел и промежуток ид.
elseif ($args.count -eq 3) {
    $choice = $args[0].ToString()
    $min_id = $args[1]
    $max_id = $args[2]
}
else { Write-Output 'Параметров должно быть не столько. Либо 0, либо 1, либо 3'; pause ; Exit }

try { $min_id  = $min_id.ToInt32($null)  } catch { $min_id = 0  }
try { $max_id  = $max_id.ToInt32($null)  } catch { $max_id = 0  }
try { $min_sid = $min_sid.ToInt32($null) } catch { $min_sid = 0 }

if ( $min_id -and $min_id -gt $max_id ) {
    Write-Host ( 'Неверные значения минимума ({0}) и максимума ({1}) ID.' -f $min_id, $max_id )
    Pause
    Exit
}


$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

Initialize-Client

Write-Output 'Получаем список раздач из клиента'
$client_torrents_list = (Read-Client 'torrents/info') | ConvertFrom-Json | % { $_.hash }

Write-Output 'Запрашиваем список раздач в разделе'
$tracker_torrents_list = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result

# Фильтруем раздачи трекера по ид раздачи
if ($min_id -gt 0) {
    $tracker_torrents_list_required = @{}
    foreach ( $key in $tracker_torrents_list.keys ) {
        if ( $key.ToInt32($null) -ge $min_id -and $key.ToInt32($null) -le $max_id ) {
            $tracker_torrents_list_required[$key] = $tracker_torrents_list[$key]
        }
    }
    $tracker_torrents_list = $tracker_torrents_list_required
}

# Фильтруем раздачи трекера по колву сидов
if ($min_sid -gt 0 ) {
    $tracker_torrents_list_required = @{}
    foreach ( $key in $tracker_torrents_list.keys ) {
        if ( $tracker_torrents_list[$key][1] -ge $min_sid ) {
            $tracker_torrents_list_required[$key] = $tracker_torrents_list[$key]
        }
    }
    $tracker_torrents_list = $tracker_torrents_list_required
}

if ( $tracker_torrents_list.count -eq 0 ) {
    Write-Output 'Не получено ни одной раздачи'
    Pause
    Exit
}

# Определить категорию новых раздач.
$category = $collector.category
if ( !$category ) {
    $category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result[$choice]
}

Write-Output 'Авторизуемся на форуме'
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker.login; 'login_password' = $rutracker.password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds > $null

# Сортируем раздачи.
$sorted = @{}
if ( $min_sid -gt 0 -and $nul -ne $min_sid ) {
    $tracker_torrents_list.keys | ForEach-Object { try { $sorted[$_] = $tracker_torrents_list[$_][1] } catch {} }
    $sorted = ( $sorted.GetEnumerator() | Sort-Object { $_.Value } -Descending ) | Where-Object { $_.Value -ne '' -and $nul -ne $_.Value }
}
else {
    $tracker_torrents_list.keys | ForEach-Object { try { $sorted[$_] = $tracker_torrents_list[$_][3] } catch {} }
    $sorted = ( $sorted.GetEnumerator() | Sort-Object { $_.Value } ) | Where-Object { $_.Value -ne '' -and $nul -ne $_.Value }
}


Write-Output 'Проверяем есть ли что добавить'
$current = 1
$added = 0
ForEach ( $id in $sorted ) {
    $ProgressPreference = 'Continue'
    Write-Progress -Activity 'Обрабатываем раздачи' -Status ( "$current всего, $added добавлено, " + ( [math]::Round( $current * 100 / $tracker_torrents_list.Keys.Count ) ) + '%' ) -PercentComplete ( $current * 100 / $tracker_torrents_list.Keys.Count )
    $ProgressPreference = 'SilentlyContinue'
    $current++

    $torrent_id = $id.Name
    $reqdata = @{'by' = 'topic_id'; 'val' = $torrent_id.ToString() }
    # по каждой раздаче с трекера ищем её hash
    try {
        $hash = (( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_tor_hash?by=topic_id&val=' + $torrent_id ) ).content | ConvertFrom-Json -AsHashtable ).result[$torrent_id].ToLower()
    }
    catch {
        Write-Output ( "Не получилось найти хэш раздачи " + $torrent_id + ". Вероятно, это и не раздача вовсе." )
        Continue
    }
    if ( $client_torrents_list -notcontains $hash ) {
        # если такого hash ещё нет в клиенте, то:
        # проверяем, что такая ещё не заархивирована
        $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id

        $zip_google_path = $google_params.folders[0] + $disk_path + $torrent_id + '_' + $hash.ToLower() + '.7z'
        if ( -not ( Test-Path $zip_google_path ) ) {
            # поглощённые раздачи пропускаем
            $info = (( Invoke-WebRequest -uri 'http://api.rutracker.org/v1/get_tor_topic_data' -body $reqdata).content
                | ConvertFrom-Json -AsHashtable ).result[$torrent_id]

            if ( -not ( $info.tor_status -eq 7 ) ) {
                # Скачиваем торрент с форума
                Write-Output ( 'Скачиваем {0} ({1}), {2}.' -f $torrent_id, (Get-BaseSize $info.size), $info.topic_title )
                $forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $torrent_id
                $torrent_file_path = $collector.tmp_folder + $OS.fsep + $torrent_id + '_collect.torrent'
                Invoke-WebRequest -Uri $forum_torrent_path -WebSession $forum_login -OutFile $torrent_file_path > $null

                # и добавляем торрент в клиент
                $extract_path = $collector.collect
                if ( $collector.sub_folder ) {
                    $extract_path = $collector.collect + $OS.fsep + $torrent_id
                }

                # Проверка на переполнение каталога с загрузками.
                if ( $collector.collect_size ) {
                    Compare-MaxSize $collector.collect $collector.collect_size
                }

                # Добавляем раздачу в клиент.
                Write-Output ( 'Добавляем торрент для раздачи {0} в клиент.' -f $torrent_id )
                Add-ClientTorrent $hash $torrent_file_path $extract_path $category > $null

                Remove-Item $torrent_file_path
                $added++

                Start-Sleep -Seconds 1
            }
        }
    }
}
