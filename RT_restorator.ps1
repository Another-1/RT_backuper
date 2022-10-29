Param (
    [ValidateRange('Positive')][int[]]$Forum,
    [ValidateRange('Positive')][int[]]$Topics,
    [ValidateSet(0, 1, 2)][string]$Priority = -1,
    [string]$Category,
    [string]$UsedClient
)

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

# Если передан список раздач. работаем с ними.
if ( $Topics.count ) {
    $request = @{ 'by' = 'topic_id'; 'val' = $Topics -Join ","}
    $tracker_result = ( Invoke-WebRequest -Uri 'https://api.t-ru.org/v1/get_tor_topic_data' -Body $request ).content | ConvertFrom-Json -AsHashtable
    $tracker_list = $tracker_result.result.GetEnumerator() | ? { $_.value } | % {
        @{
            topic_id = $_.key
            hash     = $_.value['info_hash']
            seeders  = $_.value['seeders']
            size     = $_.value['size']
            priority = -1
            status   = $_.value['tor_status']
            reg_time = $_.value['reg_time']
        }
    } | ? { $_.status -ne 7 }
}
# Идем по обычной цепочке получения всех раздач раздела.
else {
    if ( !$Forum ) {
        $forum_id = Read-IntValue 'Введите раздел'
        if ( $forum_id ) { $Forum = @( $forum_id ) }
    }
    if ( !$Forum ) { Exit }

    $Forum = $Forum | Sort-Object -Unique
    Write-Host ( 'Запрашиваем список раздач в разделах {0}' -f ($Forum -Join ",") )
    $tracker_list = @()
    foreach ( $forum_id in $Forum ) {
        try {
            $tracker_result = ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $forum_id ) ).content | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Host ( 'Не найдены раздачи в разделе {0}' -f $forum_id )
            Continue
        }
        $topic_header = [ordered]@{}; $tracker_result.format.topic_id | % -Begin { $i = 0 } { $topic_header[$_] = $i++ }

        $temp_list = $tracker_result.result.GetEnumerator() | % {
           @{
                topic_id = $_.key
                hash     = $_.value[ $topic_header['info_hash'] ]
                seeders  = $_.value[ $topic_header['seeders'] ]
                size     = $_.value[ $topic_header['tor_size_bytes'] ]
                priority = $_.value[ $topic_header['keeping_priority'] ]
                status   = $_.value[ $topic_header['tor_status'] ]
                reg_time = $_.value[ $topic_header['reg_time'] ]
            }
        } | ? { $_.status -ne 7 }

        Write-Host ( '- в разделе {0} имеется {1} раздач' -f $forum_id, $temp_list.count )

        $tracker_list += $temp_list
    }

    # Если задан приоритет, фильтруем.
    if ( $Priority -ge 0 ) {
        $tracker_list = $tracker_list | ? { $_.priority -eq $Priority }
    }
}

if ( $tracker_list.count -eq 0 ) {
    Write-Host 'По заданным фильтрам не получено ни одной раздачи.'
    Pause
    Exit
}
Write-Host ( 'После фильтрации осталось раздач: {0}.' -f $tracker_list.count )

# Получаем список существующих архивов.
$dones, $hashes = Get-Archives

# Вычисляем раздачи, у которых есть архив в облаке.
$tracker_list = $tracker_list | ? { $hashes[ $_.hash ] }
Write-Host ( 'Имеется архивов в облаке: {0}.' -f $tracker_list.count )


# Подключаемся к клиенту.
Initialize-Client
$torrents_list = Get-ClientTorrents -Completed $false | % { @{ $_.hash = 1} }

if ( $torrents_list ) {
    # Исключаем раздачи, которые уже есть в клиенте.
    $tracker_list = $tracker_list | ? { !($torrents_list[ $_.hash ]) }
    Write-Host ( 'От клиента [{0}] получено раздач: {1}. Раздач доступных к восстановлению: {2}.' -f $client.name, $torrents_list.count, $tracker_list.count )
}

# Определить категорию новых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) {
    $Category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $Forum ) ).content | ConvertFrom-Json -AsHashtable ).result[$Forum]
}
if ( !$Category ) { $Category = 'restored' }

Write-Host ''
Write-Host 'Авторизуемся на форуме'
$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

$forum_url = 'https://rutracker.org/forum/login.php'
$forum_headers = @{'User-Agent' = 'Mozilla/5.0' }
$forum_payload = @{ 'login_username' = $rutracker.login; 'login_password' = $rutracker.password; 'login' = '%E2%F5%EE%E4' }
$forum_auth = Invoke-WebRequest -Uri $forum_url -Method Post -Headers $forum_headers -Body $forum_payload -SessionVariable forum_login -Proxy $proxy_address -ProxyCredential $proxyCreds

try {
    $match = Select-String "form_token: '(.*)'" -InputObject $forum_auth.Content
    $forum_sid = $match.Matches.Groups[1].Value
} catch {
    Write-Host ( 'Ошибка авторизации: {0}' -f $Error[0] )
}
if ( !$forum_sid ) {
    Write-Host 'Не удалось авторизоваться на форуме.'
    Exit
}

Write-Host 'Перебираем раздачи'
foreach ( $torrent in $tracker_list ) {
    # Ид и прочие параметры раздачи.
    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash.ToLower()
    if ( !$torrent_id ) {
        Write-Host '[skip] Отсутсвует ид раздачи. Пропускаем.'
        Continue
    }

    $zip_path = Get-TorrentPath $torrent_id $torrent_hash

    Write-Host ( 'Проверяем гугл-диск {0}' -f $zip_path )
    # Проверяем, что архив для такой раздачи ещё не создан.
    $zip_test = Test-PathTimer $zip_path
    Write-Host ( '[check] Проверка выполнена за {0} сек, результат: {1}' -f $zip_test.exec, $zip_test.result )
    if ( !$zip_test.result ) {
        Write-Host '[skip] Не удалось найти архив для раздачи в облаке.'
        Continue
    }

    $extract_path = $collector.collect
    if ( $collector.sub_folder ) {
        $extract_path = $collector.collect + $OS.fsep + $torrent_id
    }

    Write-Output "Распаковываем $zip_path"
    New-Item -ItemType Directory -Path $extract_path -Force > $null
    if ( $backuper.h7z ) {
        & $backuper.p7z x "$zip_path" "-p$pswd" "-aoa" "-o$extract_path" > $null
    } else {
        & $backuper.p7z x "$zip_path" "-p$pswd" "-aoa" "-o$extract_path"
    }

    if ( $LastExitCode -ne 0 ) {
        Write-Host ( '[check] Ошибка распаковки архива, код ошибки: {0}.' -f $LastExitCode )
        Continue
    }

    Write-Output ( 'Скачиваем торрент для раздачи {0} с форума.' -f $torrent_id )
    $forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $torrent_id
    $torrent_file_path = $collector.tmp_folder + $OS.fsep + $torrent_id + '_restore.torrent'

    New-Item -ItemType Directory -Path $collector.tmp_folder -Force > $null
    Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile $torrent_file_path > $null

    # Добавляем раздачу в клиент.
    Write-Output ( 'Добавляем торрент для раздачи {0} в клиент.' -f $torrent_id )
    New-Item -ItemType Directory -Path $extract_path -Force > $null
    Add-ClientTorrent $torrent_hash $torrent_file_path $extract_path $Category > $null
    Remove-Item $torrent_file_path

    Start-Sleep -Seconds 1
}
