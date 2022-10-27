Param (
    [int]$Forum,
    [int]$MinTopic   = -1,
    [int]$MaxTopic   = -1,
    [int]$MinSeed = -1,
    [ValidateSet(0, 1, 2)][string]$Priority = -1,
    [ValidateSet('topic_id', 'seeders', 'size', 'priority')][string]$Sort = 'size',
    [ValidateRange('Positive')][int]$Top = 10000,
    [switch]$Descending,
    [ValidateRange('Positive')][int[]]$Topics,
    [int]$SizeLimit = 1024,
    [string]$Category,
    [string]$UsedClient
)

function Read-IntValue ( $Prompt ) {
    try {
        $int = [int]( Read-Host -Prompt $Prompt )
    } catch {
        $int = 0
    }
    return $int
}

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

# Если передан список раздач. получаем их и с ними работаем.
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
        $Forum = [int]( Read-Host -Prompt 'Выберите раздел' )
    }
    if ( !$Forum ) { Exit }

    Write-Host ( 'Запрашиваем список раздач в разделе {0}' -f $Forum )
    $tracker_result = ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $Forum ) ).content | ConvertFrom-Json -AsHashtable
    $topic_header = [ordered]@{}; $tracker_result.format.topic_id | % -Begin { $i = 0 } { $topic_header[$_] = $i++ }

    $tracker_list = $tracker_result.result.GetEnumerator() | % {
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

    Write-Host ( '- в разделе {0} имеется {1} раздач' -f $Forum, $tracker_list.count )

    if ( $MinTopic -lt 0 ) {
        $MinTopic = Read-IntValue 'Минимальный ID (опционально)'
    }
    if ( $MaxTopic -lt 0 ) {
        $MaxTopic = Read-IntValue 'Максимальный ID (опционально)'
    }
    if ( $MinSeed -lt 0 ) {
        $MinSeed = Read-IntValue 'Минимальное количество сидов (опционально)'
    }

    if ( $MinTopic -and $MaxTopic -and $MinTopic -ge $MaxTopic ) {
        Write-Host ( 'Неверные значения минимума ({0}) и максимума ({1}) ID.' -f $MinTopic, $MaxTopic )
        Pause
        Exit
    }

    $Priorities = @{ '-1' = 'не задан'; '0' = 'низкий'; '1' = 'обычный'; '2' = 'высокий' }
    $text = 'Параметры фильтрации: ID от {0} до {1}, сиды >{2}, приоритет {3}, сортировка по {4}'
    Write-Host ( $text -f $MinTopic, $MaxTopic, $MinSeed, $Priorities[$Priority], $Sort ) -ForegroundColor Green

    # Если задан приоритет, фильтруем.
    if ( $Priority -ge 0 ) {
        $tracker_list = $tracker_list | ? { $_.priority -eq $Priority }
    }

    # Если задан минимум сидов, фильтруем.
    if ( $MinSeed -gt 0 ) {
        $tracker_list = $tracker_list | ? { $_.seeders -ge $MinSeed }
    }

    # Если задан минимум ид раздачи, фильтруем.
    if ( $MinTopic -gt 0 ) {
        $tracker_list = $tracker_list | ? { $_.topic_id -ge $MinTopic }
    }
    # Если задан максимум ид раздачи, фильтруем.
    if ( $MaxTopic -gt 0 ) {
        $tracker_list = $tracker_list | ? { $_.topic_id -le $MaxTopic }
    }

}

if ( $tracker_list.count -eq 0 ) {
    Write-Host 'По заданным фильтрам не получено ни одной раздачи.'
    Pause
    Exit
}
Write-Host ( 'После фильтрации осталось раздач: {0}.' -f $tracker_list.count )

Initialize-Client
Write-Host 'Получаем список раздач из клиента..'
$client_list = Get-ClientTorrents -Completed $false | % { $_.hash }

$tracker_list = $tracker_list | ? { $_.hash -notin $client_list }
Write-Host ( '- от клиента получено раздач: {0}, после их исключения, раздач осталось: {1}.' -f $client_list.count, $tracker_list.count )
if ( $Top -lt 10000 ) {
    Write-Host ( '- будет добавлено первых {0} раздач.' -f $Top )
}

# Определить категорию новых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) {
    $Category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $Forum ) ).content | ConvertFrom-Json -AsHashtable ).result[$Forum]
}

# Сортируем по заданному полю (size по-умолчанию).
$tracker_list = $tracker_list | Sort-Object -Top $Top -Property @{Expression = $Sort; Descending = $Descending}

Write-Host 'Авторизуемся на форуме'
$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

$forum_url = 'https://rutracker.org/forum/login.php'
$forum_headers = @{'User-Agent' = 'Mozilla/5.0' }
$forum_payload = @{ 'login_username' = $rutracker.login; 'login_password' = $rutracker.password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -Uri $forum_url -Method Post -Headers $forum_headers -Body $forum_payload -SessionVariable forum_login -Proxy $proxy_address -ProxyCredential $proxyCreds > $null

$current = 1
$added = 0
[long]$SizeLimit = ($SizeLimit * [math]::Pow(1024, 3)) # Гб
[long]$SizeUsed = 0
foreach ( $torrent in $tracker_list ) {
    $ProgressPreference = 'Continue'
    $perc = [math]::Round( $current * 100 / $tracker_list.count )
    Write-Progress -Activity 'Обрабатываем раздачи' -Status ( "$current всего, $added добавлено, $perc %" ) -PercentComplete $perc
    $ProgressPreference = 'SilentlyContinue'
    $current++

    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash

    # Проверяем, наличие раздачи в облаке.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id
    $zip_google_path = $google_params.folders[0] + $disk_path + $torrent_id + '_' + $torrent_hash.ToLower() + '.7z'
    if ( Test-Path $zip_google_path ) {
        Write-Host ( 'Раздача уже имеется в облаке {0}.' -f $torrent_id )
        Continue
    }

    # Скачиваем торрент с форума
    Write-Host ( 'Скачиваем торрент-файл раздачи {0} ({1}).' -f $torrent_id, (Get-BaseSize $torrent.size) )
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
    Write-Host ( 'Добавляем торрент-файл раздачи {0} в клиент.' -f $torrent_id )
    Add-ClientTorrent $torrent_hash $torrent_file_path $extract_path $Category > $null

    Remove-Item $torrent_file_path
    $added++

    $SizeUsed += $torrent.size
    if ( $SizeUsed -ge $SizeLimit ) {
        Write-Host ( 'Размер добавленных раздач ({0}) превышает заданный лимит ({1}). Завершаем работу.' -f (Get-BaseSize $SizeUsed), (Get-BaseSize $SizeLimit) )
        Pause
        Exit
    }

    Start-Sleep -Seconds 1
} # end foreach
