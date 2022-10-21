. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }


$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

Write-Output 'Смотрим, что уже заархивировано'
$archives = @{}
$hashes_tmp = @{}
$hashes = @{}
( get-childitem( $google_params.folders[0] ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem( $_ ) } | `
    Sort-Object -Property CreationTime -Descending | ForEach-Object { try {
        $archives[($_.Name.split('_')[0])] = $_.FullName
        $hashes_tmp[($_.Name.split('_')[0])] = $_.name.Split('_')[1].split('.')[0]
    }
    catch {}
}
$hashes_tmp.keys | ForEach-Object { $hashes[$hashes_tmp[$_]] = $_ }
$hashes_tmp = @{}

if ( $args ) {
    $choice = $args[0]
    Write-Host "Выбранный раздел: $choice"
} else {
    $choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()
}

$category = $collector.category
if ( !$category ) {
    $category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result[[string]$choice]
}
if ( !$category ) { $category = 'restored' }

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

# Подключаемся к клиенту.
Initialize-Client

Write-Output 'Получаем список раздач из клиента'
$client_torrents_list = [string[]]( Read-Client 'torrents/info' ) | ConvertFrom-Json | % { $_.hash }

Write-Output 'Исключаем раздачи, которые уже есть в клиенте'
$hashes = @{}
$hashes_required.keys | ? { $_ -notin $client_torrents_list } | ForEach-Object { $hashes[$_] = $hashes_required[$_] } 
Remove-Variable -name hashes_required

if ( !$hashes.count ) {
    Write-Host 'Нет раздач для восстановления.'
    Exit
}

$archives = @{}
$hashes.Values | ForEach-Object { $archives[$_] = $archives_required[$_] }
Remove-Variable -name archives_required

Write-Output 'Авторизуемся на форуме'
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker.login; 'login_password' = $rutracker.password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds > $null

Write-Host 'Перебираем раздачи'
foreach ( $hash in $hashes.Keys ) {
    if ( $nul -eq ( $client_torrents_list[$hash])) {
        $torrent_id = $hashes[$hash]
        $filename = $archives[$torrent_id]
        Write-Output "Распаковываем $filename"

        $extract_path = $collector.collect
        if ( $collector.sub_folder ) {
            $extract_path = $collector.collect + $OS.fsep + $torrent_id
        }

        New-Item -ItemType Directory -Path $extract_path -Force > $null
        if ( $backuper.h7z ) {
            & $backuper.p7z x "$filename" "-p$pswd" "-o$extract_path" > $null
        } else {
            & $backuper.p7z x "$filename" "-p$pswd" "-o$extract_path"
        }

        Write-Output ( 'Скачиваем торрент для раздачи {0} с форума.' -f $torrent_id )
        New-Item -ItemType Directory -Path $collector.tmp_folder -Force > $null
        $forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $torrent_id
        $torrent_file_path = $collector.tmp_folder + $OS.fsep + $torrent_id + '_restore.torrent'
        Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile $torrent_file_path > $null

        # Добавляем раздачу в клиент.
        Write-Output ( 'Добавляем торрент для раздачи {0} в клиент.' -f $torrent_id )
        Add-ClientTorrent $hash $torrent_file_path $extract_path $category > $null
        Remove-Item $torrent_file_path

        Start-Sleep -Seconds 1
    }
}
