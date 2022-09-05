# осздавать ли подкаталоги по ID для раздачи. 1 - создавать, 0 - не надо
$torrent_folders = 0

# каталог временных файлов для скачивания .torrent
$temp_folder = 'C:\TEMP'

# каталог для распаковки добавляемых раздач
$store_path = 'E:\Хранимое\Прочее'

# тут указываем каталог общих папок Google Drive.
$google_folder = 'M:\Shared drives'

# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8082'

# учётные данные для WebUI qBittorrent.
$webui_login = 'login'
$webui_password = 'password'

# ссылка на архиватор 7z
$7z_path = 'c:\Program Files\7-Zip\7z.exe'

# пароль на распаковку архивов. Следует оставить как есть если не требуется иное в явном виде.
$archive_password = '20RuTracker.ORG22'

# учётные данные форума
$rutracker_login = 'forum_login'
$rutracker_password = 'forum_password'

# адрес и пароль прокси-сервера
$proxy_address = 'http://45.8.144.130:3128'
$proxy_password = 'Sgssqb19Ijg'

##### Дальше начинается собственно код, там в идеале ничего менять не нужно.
$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList "keepers", $secure_pass

Write-Output 'Смотрим, что уже заархивировано'
$archives = @{}
$hashes_tmp = @{}
$hashes = @{}
( get-childitem( $google_folder ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem( $_ ) } | `
    Sort-Object -Property CreationTime -Descending | ForEach-Object { try {
        $archives[($_.Name.split('_')[0])] = $_.FullName
        $hashes_tmp[($_.Name.split('_')[0])] = $_.name.Split('_')[1].split('.')[0]
    }
    catch {}
}
$hashes_tmp.keys | ForEach-Object { $hashes[$hashes_tmp[$_]] = $_ }
$hashes_tmp = @{}

$choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()

Write-Output 'Запрашиваем c трекера список раздач в разделе'
$tracker_torrents_list = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result

if ( $tracker_torrents_list.count -eq 0) {
    Write-Output 'Не получено ни одной раздачи'
    Pause
    Exit
}

Write-Output 'Отбрасываем архивы не по указанному разделу'
$archives_required = @{}
$archives.keys | Where-Object { $nul -ne $tracker_torrents_list[$_] } | ForEach-Object { $archives_required[$_] = $archives[$_] }
$hashes_required = @{}
$hashes.keys | Where-Object { $nul -ne $tracker_torrents_list[$hashes[$_]] } | ForEach-Object { $hashes_required[$_] = $hashes[$_] }

Write-Output 'Авторизуемся в клиенте'
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul

Write-Output 'Получаем список раздач из клиента'
$client_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' ) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object hash

Write-Output 'Исключаем раздачи, которые уже есть в клиенте'
$hashes = @{}
$hashes_required.keys | Where-Object { $nul -eq $client_torrents_list[$_] } | ForEach-Object { $hashes[$_] = $hashes_required[$_] } 
Remove-Variable -name hashes_required
$archives = @{}
$hashes.Values | ForEach-Object { $archives[$_] = $archives_required[$_] }
Remove-Variable -name archives_required

Write-Output 'Авторизуемся на форуме'
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker_login; 'login_password' = $rutracker_password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds | Out-Null

foreach ( $hash in $hashes.Keys ) {
    if ( $nul -eq ( $client_torrents_list[$hash])) {
        $id = $hashes[$hash]
        $filename = $archives[$id]
        if ( $torrent_folders -eq 1 ) {
            $extract_path = $store_path + '\' + $id
        }
        else {
            $extract_path = $store_path
        }
        Write-Output "Распаковываем $filename"
        New-Item -path $extract_path -ErrorAction SilentlyContinue
        & $7z_path e "$filename" "-p$archive_password" "-o$extract_path"

        Write-Output "Скачиваем торрент с форума"
        $forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $id
        Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile ( $temp_folder + '\temp.torrent') | Out-Null

        Write-Output "Добавляем торрент в клиент"
        $dl_url = @{
            name     = 'torrents'
            torrents = get-item 'C:\temp\temp.torrent'
            savepath = $extract_path
        }
        Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/add' ) -form $dl_url -WebSession $sid -Method POST -ContentType 'application/x-bittorrent' | Out-Null
    }
}
