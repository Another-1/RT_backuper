Param (
    [ValidateRange('Positive')][int[]]$Forum,
    [ValidateRange('NonNegative')][int]$MinTopic = -1,
    [ValidateRange('NonNegative')][int]$MaxTopic = -1,
    [ValidateRange('NonNegative')][int]$MinSeed  = -1,
    [ValidateRange('Positive')][int]$MinSize, #Мб
    [ValidateSet(0, 1, 2)][string]$Priority = -1,
    [ValidateSet('topic_id', 'seeders', 'size', 'priority')][string]$Sort = 'size',
    [ValidateRange('Positive')][int]$First,
    [switch]$Descending,
    [ValidateRange('Positive')][int[]]$Topics,
    [ValidateRange('Positive')][int]$SizeLimit = 1024, #Гб
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
    # Если задан минимальный размер раздачи, фильтруем.
    if ( $MinSize -gt 0 ) {
        [long]$MinSize = $MinSize * [math]::Pow(1024, 2) # Мб
        $tracker_list = $tracker_list | ? { $_.size -ge $MinSize }
    }

}

if ( $tracker_list.count -eq 0 ) {
    Write-Host 'По заданным фильтрам не получено ни одной раздачи.'
    Pause
    Exit
}
Write-Host ( 'После фильтрации осталось раздач: {0}.' -f $tracker_list.count )

# Подключаемся к клиенту.
Initialize-Client
Write-Host 'Получаем список раздач из клиента..'
$torrents_list = Get-ClientTorrents -Completed $false | % { @{ $_.hash = 1} }
if ( $torrents_list ) {
    # Исключаем раздачи, которые уже есть в клиенте.
    $tracker_list = $tracker_list | ? { !($torrents_list[ $_.hash ]) }
    Write-Host ( '- от клиента получено раздач: {0}, после их исключения, раздач осталось: {1}.' -f $torrents_list.count, $tracker_list.count )
}
if ( $First -or $SizeLimit ) {
    Write-Host ( '- будет добавлено первых {0} раздач или первые {1} GiB.' -f $First, $SizeLimit )
}

# Определить категорию новых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) {
    $Category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $Forum ) ).content | ConvertFrom-Json -AsHashtable ).result[$Forum]
}
if ( !$Category ) { $Category = 'temp' }

# Сортируем по заданному полю (size по-умолчанию).
$tracker_list = $tracker_list | Sort-Object -Property @{Expression = $Sort; Descending = $Descending}

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

$current = 1
$added = 0
[long]$SizeLimit = ($SizeLimit * [math]::Pow(1024, 3)) # Гб
[long]$SizeUsed = 0
Write-Host 'Перебираем раздачи'
foreach ( $torrent in $tracker_list ) {
    $ProgressPreference = 'Continue'
    $perc = [math]::Round( $current * 100 / $tracker_list.count )
    Write-Progress -Activity 'Обрабатываем раздачи' -Status ( "$current всего, $added добавлено, $perc %" ) -PercentComplete $perc
    $ProgressPreference = 'SilentlyContinue'
    $current++

    # Ид и прочие параметры раздачи.
    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash.ToLower()
    if ( !$torrent_id ) {
        Write-Host '[skip] Отсутсвует ид раздачи. Пропускаем.'
        Continue
    }

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
    
    New-Item -ItemType Directory -Path $collector.tmp_folder -Force > $null
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
    New-Item -ItemType Directory -Path $extract_path -Force > $null
    Add-ClientTorrent $torrent_hash $torrent_file_path $extract_path $Category > $null
    Remove-Item $torrent_file_path

    $added++
    $SizeUsed += $torrent.size
    $errors = @()
    if ( $First -and $added -ge $First ) {
        $errors += 'Количество добавленных раздач ({0}) равно лимиту ({1}). Завершаем работу.' -f $added, $First
    }
    if ( $SizeLimit -and $SizeUsed -ge $SizeLimit ) {
        $errors += 'Размер добавленных раздач ({0}) равно лимиту ({1}). Завершаем работу.' -f (Get-BaseSize $SizeUsed), (Get-BaseSize $SizeLimit)
    }
    if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Pause; Exit }

    Start-Sleep -Seconds 1
} # end foreach
