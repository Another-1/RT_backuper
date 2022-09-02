# тут указываем каталог общих папок Google Drive. Слэш на конце добавлять не надо.
$google_folder = 'M:\Shared drives'

# тут указываем диск, на котором находится папка временных файлов клиента Google Drive (можно посмотреть и передвинуть в "Настройки" - Шестерёнка справа-сверху - "Локальная папка для хранения файлов из кеша").
# нужно для того, чтобы сделать паузу на закачивание при архивировании, если эта папка переполнится, и скинуть очередной архив будет некуда.
$drive_fs = 'K'

# тут нужно указать временный локальный диск, на котором будут создаваться архивы до того, как будут переложены в папку гуглодиска, чтобы оне не пытался начинать закачку по мере архивации. Возможно, это и не требуется. 
$tmp_drive = 'E'

# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8082'

# учётные данные для WebUI qBittorrent.
$webui_login = 'login'
$webui_password = 'password'

# ссылка на архиватор 7z
$7z_path = 'c:\Program Files\7-Zip\7z.exe'

#  пароль на создаваемые архивы. Следует оставить как есть если не требуется иное в явном виде.
$archive_password = '20RuTraсker.ORG22'

##### Дальше начинается собственно код, там в идеале ничего менять не нужно.
##### разве что при желании можно скорректировать опции архивации.

# лимит закачки на один диск в сутки
$lv_750gb = 740 * 1024 * 1024 * 1024

Write-Output 'Смотрим, что уже заархивировано'
$dones = @{}
# ( get-childitem( $google_folder ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem( $_ ) } | ForEach-Object { $dones[$_.Name.split('_')[0]] = 1 }
( get-childitem( $google_folder ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem( $_ ) } | ForEach-Object { $dones[$_.BaseName.ToLower()] = 1 }

Write-Output 'Авторизуемся в клиенте'
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul

# получаем список раздач из клиента
if ( $args.Count -eq 0) {
    Write-Output 'Получаем список раздач из клиента'
    $all_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' ) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, state, size, category, completion_on, added_on  | sort-object -Property size
    $torrents_list = $all_torrents_list | Where-Object { $_.state -ne 'downloading' -and $_.state -ne 'stalledDL' -and $_.state -ne 'queuedDL' -and $_.state -ne 'error' -and $_.state -ne 'missingFiles' }
    Write-Output 'Получаем номера топиков по раздачам'
}
else {
    Write-Output 'Получаем общую информацию о раздаче из клиента'
    $reqdata = 'hashes=' + $args[0]
    $torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?' + $reqdata) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, state, size, category, completion_on | Where-Object { $_.state -ne 'downloading' -and $_.state -ne 'stalledDL' -and $_.state -ne 'queuedDL' -and $_.state -ne 'error' -and $_.state -ne 'missingFiles' } | sort-object -Property size
    Write-Output 'Получаем номер топика из раздачи'
}

# по каждой раздаче получаем коммент, чтобы достать из него номер топика
foreach ( $torrent in $torrents_list ) {
    $reqdata = 'hash=' + $torrent.hash
    try { $torprops = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/properties' ) -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json }
    catch { pause }
    $torrent.state = ( Select-String "\d*$" -InputObject $torprops.comment).Matches.Value
}
if ( $args.Count -eq 0) {
    $torrents_list_required = [System.Collections.ArrayList]::new()
    Write-Output 'Пропускаем уже заархивированные раздачи'
    $torrents_list | ForEach-Object {
        if ( $_.state -ne '' -and $nul -eq $dones[( $_.state  + '_' + $_.hash.ToLower())] ) {
            $torrents_list_required += $_
        }
    }
    Write-Output( 'Пропущено ' + ( $torrents_list.count - $torrents_list_required.count ) + ' раздач')
    $torrents_list = $torrents_list_required
}

$proc_size = 0
$proc_cnt = 0
$uploads_all = @{}
$sum_size = ( $torrents_list | Measure-Object -sum size ).Sum
$sum_cnt = $torrents_list.count
$used_locs = [System.Collections.ArrayList]::new()
$ok = $true

Write-Output 'Проверяем уникальность путей сохранения раздач'
foreach ( $torrent in $torrents_list ) {
    if ( $used_locs.keys -contains $torrent.content_path ) {
        Write-Output ( 'Несколько раздач хранятся по пути "' + $torrent.content_path + '" !')
        Write-Output ( 'Нажмите любую клавищу, исправьте и начните заново !')
        $ok = $false
    }
    else {
        $used_locs += $torrent.content_path
    }
}
If ( $ok -eq $false)  {
    pause
    Exit
}

foreach ( $torrent in $torrents_list ) {
    $folder_name = '\ArchRuT_' + ( 300000 * [math]::Truncate(( $torrent.state - 1 )/ 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $torrent.state - 1 ) / 300000) + 1 ) + '\'
    $zip_name = $google_folder + $folder_name + $torrent.state + '_' + $torrent.hash.ToLower() + '.7z'
        $tmp_zip_name = ( $tmp_drive + ':\' + $torrent.state + '_' + $torrent.hash + '.7z' )
        if ( -not ( test-path -Path $zip_name ) ) { 
            Remove-Item -path $tmp_zip_name -Force -ErrorAction SilentlyContinue
            Write-Output ( "`n$($psstyle.Foreground.Cyan ) Архивируем " + $torrent.category + ', ' + $torrent.name + $psstyle.Reset)
            $param_sting = "-p$archive_password"
            if ( $args.Count -eq 0 ) {
                & $7z_path a $tmp_zip_name $torrent.content_path $param_sting -mx2 -mmt4 -mhe -sccUTF-8 -bb0
                $zip_size = (Get-Item $tmp_zip_name).Length
                $now = Get-date
                $daybefore = $now.AddDays( -1 )
                $uploads_tmp = @{}
                $uploads = $uploads_all[ $folder_name ]
                $uploads.keys | Where-Object { $_ -ge $daybefore } | ForEach-Object { $uploads_tmp += @{ $_ = $uploads[$_] } }
                $uploads = $uploads_tmp
                $uploads += @{ $now = $zip_size }
                $today_size = ( $uploads.values | Measure-Object -sum ).Sum
                while ( $today_size -gt $lv_750gb ) {
                    Write-Output ( "Дневной трафик по диску " + $folder_name + " уже " + [math]::Round( $today_size / 1024 / 1024 / 1024 ) )
                    Write-Output 'Подождём часик чтобы не выйти за 750 Гб. (сообщение будет повторяться пока не выйдем)'
                    Start-Sleep -Seconds (60 * 60 )
                    $now = Get-date
                    $daybefore = $now.AddDays( -1 )
                    $uploads_tmp = @{}
                    $uploads.keys | Where-Object { $_ -ge $daybefore } | ForEach-Object { $uploads_tmp += @{ $_ = $uploads[$_] } }
                    $uploads = $uploads_tmp
                    $today_size = ( $uploads.values | Measure-Object -sum ).Sum
                }
                $uploads_all[$folder_name] = $uploads

                $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
                while ( $zip_size -gt ( $fs - 10000000 ) ) {
                    Write-Output ( 'Мало места на временном диске, подождём пока станет больше чем ' + ([int]($zip_size / 1024 / 1024)).ToString() + ' Мб')
                    Start-Sleep -Seconds 600
                    $fs = ( Get-PSDrive $drive_fs | Select-Object Free ).free
                }
                Write-Output ( ( [math]::Round( $today_size / 1024 / 1024 / 1024 ) ).ToString() + ' пока ещё меньше чем ' + ( $lv_750gb / 1024 / 1024 / 1024 ).ToString() + ', продолжаем' )
            }
            else {
                & $7z_path a $tmp_zip_name $torrent.content_path $param_sting -mx0 -mmt4 -mhe -sccUTF-8 -bb0
            }
            try {
                Write-Output 'Перемещаем архив на гугл-диск...'
                Move-Item -path $tmp_zip_name -destination ( $zip_name ) -Force
                Write-Output 'Готово.'
            }
            catch {
                Write-Output 'Не удалось отправить файл на гугл-диск'
                Pause
            }
            Write-Output ( 'Обработано ' + $proc_cnt + ' раздач (' + ( [math]::Round( $proc_size / 1024 / 1024 / 1024 ) ).ToString() + ' Гб) из ' + $sum_cnt + ' (' + ( [math]::Round( $sum_size / 1000 / 1000 / 1000 ) ).ToString() + ' Гб)' )
        }
        else {
            # Write-Output ( 'Пропускаем ' + $torrent.category + ', ' + $torrent.name )
        }
    $proc_size += $torrent.size
    $proc_cnt++
}
