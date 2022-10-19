# адрес, логин и пароль прокси-сервера
$proxy_address = 'http://45.8.144.130:3128'
$proxy_login = 'keepers'
$proxy_password = 'Sgssqb19Ijg'

# использовать прокси? 1 = да, 0 = нет
$use_proxy = 0

# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8083'

# учётные данные для WebUI qBittorrent.
$webui_login = 'admin'
$webui_password = 'password'

# каталог с общедоступными дисками
$google_folder = 'Q:\Shared drives'

# категория восстанавливаемых раздач
$category = 'Resume'

# каталог для распаковки раздач
$store_path = 'C:\Download'

# ссылка на архиватор 7z
$7z_path = 'c:\Program Files\7-Zip\7z.exe'

# учётные данные форума
$rutracker_login = 'login'
$rutracker_password = 'password'

####################################################################################################

$ProgressPreference = 'SilentlyContinue'

if ( $args.count -eq 0 ) { Write-Output 'Укажите ID раздачи'; Exit }
if ( $args.count -gt 2 ) { Write-Output 'Параметр может быть только один'; Exit }

$id = $args[0]

if ( $PSVersionTable.OS.ToLower().contains('windows')) { $separator = '\' } else { $separator = '/' }

$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

If ($args.count -eq 2 ) { Write-Output 'Запрашиваем с трекера ID раздачи' }
try {
    $hash = ( ( Invoke-WebRequest -Uri ( 'http://api.t-ru.org/v1/get_tor_hash?by=topic_id&val=' + $id ) ).content | ConvertFrom-Json -AsHashtable ).result[$id.ToString()].ToLower()
}
catch {
    Write-Output '0-0'; Exit 
}

if ( $null -eq $hash ) { If ($args.count -eq 2 ) { Write-Output 'Хэш не найден, выходим'; Write-Output '0-0'; Exit } }

$folder_name = 'ArchRuT_' + ( 300000 * [math]::Truncate(( $id - 1 ) / 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $id - 1 ) / 300000) + 1 )
$file_name = $google_folder + $separator + $folder_name + $separator + $id + '_' + $hash + '.7z'

If ($args.count -eq 2 ) { Write-Output 'Авторизуемся в клиенте' }
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul

If ($args.count -eq 2 ) { Write-Output 'Проверяем, нет ли уже её в клиенте' }
Remove-Variable -Name client_torrent -ErrorAction SilentlyContinue
try {
    $client_torrent = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/properties?hash=' + $hash ) -WebSession $sid ).Content | ConvertFrom-Json -AsHashtable
}
catch { }

if ( $null -ne $client_torrent ) {
    If ($args.count -eq 2 ) { Write-Output 'Раздача уже есть в клиенте, выходим' }
    Write-Output '1-1-1'
    Exit
}

If ($args.count -eq 2 ) { Write-Output 'Авторизуемся на форуме' }
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker_login; 'login_password' = $rutracker_password; 'login' = '%E2%F5%EE%E4' }
if ( $use_proxy -eq 1 ) {
    Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds | Out-Null
}
else {
    Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers | Out-Null
}
    
If ($args.count -eq 2 ) { Write-Output "Распаковываем $file_name" }

$store_path_fin = $store_path + $separator + $id
New-Item -path $store_path_fin -ErrorAction SilentlyContinue -ItemType Directory | Out-Null
& $7z_path x "$file_name" "-p20RuTracker.ORG22" "-o$store_path_fin" "-y" "-bb0" | Out-Null

If ($args.count -eq 2 ) { Write-Output "Скачиваем торрент с форума" }
$forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $id
if ( $use_proxy -eq 1 ) {
Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile ( $store_path + $separator + 'temp.torrent' ) -Proxy $proxy_address -ProxyCredential $proxyCreds | Out-Null
}
else {
    Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile ( $store_path + $separator + 'temp.torrent' ) | Out-Null    
}
If ($args.count -eq 2 ) { Write-Output "Добавляем торрент в клиент" }
$dl_url = @{
    name        = 'torrents'
    torrents    = get-item ( $store_path + $separator + 'temp.torrent' )
    savepath    = $store_path_fin
    category    = $category
    root_folder = 'false'
}
try {
    Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/add' ) -form $dl_url -WebSession $sid -Method POST -ContentType 'application/x-bittorrent' | Out-Null
    Write-Output '1-1-1'
}
catch {
    Write-Output '1-1-0'
}
Remove-Item -Path ( $store_path + $separator + 'temp.torrent' )

If ( $args.count -eq 2 ) { Write-Output "Удаляем старое" }
$client_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?category=' + $category ) -WebSession $sid ).Content | ConvertFrom-Json -AsHashtable
If ( $client_torrents_list.Count -gt 0 ) {
    Foreach ( $torrent in $client_torrents_list ) {
        if ( ( ( Get-Date( $torrent.last_activity ) -UFormat %s ) -gt 0 ) -and ( Get-Date( $torrent.last_activity ) -UFormat %s ) -lt ( ( Get-Date -UFormat %s ) - ( 3 * 86400 ) ) ) {
            try {
                Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete?hashes=' + $torrent.hash + '&deleteFiles=true' ) -WebSession $sid -Method POST > $nul
            }
            catch { }
        }
    }
}
