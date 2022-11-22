Param (
    [ValidateRange('Positive')][int[]]$Forums,
    [ValidateRange('NonNegative')][int]$MinTopic = 0,
    [ValidateRange('NonNegative')][int]$MaxTopic = 0,
    [ValidateRange('NonNegative')][int]$MinSeed  = 0,
    [ValidateRange('NonNegative')][int]$MinSize, #Мб
    [ValidateSet(0, 1, 2)][string]$Priority = -1,
    [ValidateSet('topic_id', 'seeders', 'size', 'priority')][string]$Sort = 'size',
    [switch]$Descending,
    [ValidateRange(0,12)][int]$Status,
    [ValidateRange('Positive')][int[]]$Topics,

    [ValidateRange('NonNegative')][int]$First,
    [ValidateRange('NonNegative')][int]$TopicsTotal,
    [ValidateRange('NonNegative')][int]$SizeLimit = 1024, #Гб
    [ValidateRange('NonNegative')][int]$SizeTotal, #Гб
    [switch]$StartPaused,

    [string]$Category,
    [switch]$Analyze,
    [switch]$NoCloud,
    [switch]$DryRun,
    [switch]$Verbose,

    [ArgumentCompleter({ param($cmd, $param, $word) [array](Get-Content "$PSScriptRoot/clients.txt") -like "$word*" })]
    [string]
    $UsedClient
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

$ScriptName = (Get-Item $PSCommandPath).BaseName

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings -Mode $ScriptName ) ) { Pause; Exit }

if ( !$collector.collect ) {
    $collector.collect = Get-ClientDownloadDir
}
if ( !$collector.collect ) {
    Write-Host 'Каталог хранения раздач ($collector.collect) не задан.'
    Exit
}
New-Item -ItemType Directory -Path $collector.collect -Force > $null
if ( $collector.sub_folder ) {
    Clear-EmptyFolders $collector.collect
}

# Если передан список раздач. работаем с ними.
if ( $Topics.count ) {
    $tracker = Get-ForumTopics -Topics $Topics -Status $Status
    $tracker_list = $tracker.topics
}
# Идем по обычной цепочке получения всех раздач раздела.
else {
    if ( !$Forums ) {
        $askLimit = $true
        $forum_id = Read-IntValue 'Введите раздел'
        if ( $forum_id ) { $Forums = @( $forum_id ) }
    }
    if ( !$Forums ) { Exit }

    # Если параметры не заданы через консоль, то спрашиваем фильтры.
    if ( $askLimit ) {
        if ( $MinTopic -le 0 ) {
            $MinTopic = Read-IntValue 'Минимальный ID (опционально)'
        }
        if ( $MaxTopic -le 0 ) {
            $MaxTopic = Read-IntValue 'Максимальный ID (опционально)'
        }
        if ( $MinSeed -le 0 ) {
            $MinSeed = Read-IntValue 'Минимальное количество сидов (опционально)'
        }
    }
    # Если только анализ раздела, перезаписываем фильтры.
    if ( $Analyze ) {
        $MinTopic = $MaxTopic = $MinSeed = $MinSize = 0
    }

    if ( $MinTopic -and $MaxTopic -and $MinTopic -ge $MaxTopic ) {
        Write-Host ( 'Неверные значения минимума ({0}) и максимума ({1}) ID.' -f $MinTopic, $MaxTopic )
        Pause
        Exit
    }

    $tracker = Get-ForumTopics -Forums $Forums
    $tracker_list = $tracker.topics

    $Priorities = @{ '-1' = 'не задан'; '0' = 'низкий'; '1' = 'обычный'; '2' = 'высокий' }
    $text = 'Параметры фильтрации: ID от {0} до {1}, сиды >{2}, приоритет {3}, сортировка по {4}'
    Write-Host ( $text -f $MinTopic, $MaxTopic, $MinSeed, $Priorities[$Priority], $Sort ) -ForegroundColor Green

    # Если задан приоритет, фильтруем.
    if ( $Priority -ge 0 ) {
        $tracker_list = @( $tracker_list | ? { $_.priority -eq $Priority } )
    }

    # Если задан минимум сидов, фильтруем.
    if ( $MinSeed -gt 0 ) {
        $tracker_list = @( $tracker_list | ? { $_.seeders -ge $MinSeed } )
    }

    # Если задан минимум ид раздачи, фильтруем.
    if ( $MinTopic -gt 0 ) {
        $tracker_list = @( $tracker_list | ? { $_.topic_id -ge $MinTopic } )
    }
    # Если задан максимум ид раздачи, фильтруем.
    if ( $MaxTopic -gt 0 ) {
        $tracker_list = @( $tracker_list | ? { $_.topic_id -le $MaxTopic } )
    }
    # Если задан минимальный размер раздачи, фильтруем.
    if ( $MinSize -gt 0 ) {
        [long]$MinSize = $MinSize * [math]::Pow(1024, 2) # Мб
        $tracker_list = @( $tracker_list | ? { $_.size -ge $MinSize } )
    }
}

if ( !$tracker_list ) {
    Write-Host 'По заданным фильтрам не получено ни одной раздачи.' -ForegroundColor Green
    Exit
}
Write-Host ( '- после фильтрации осталось раздач: {0}.' -f $tracker_list.count )

if ( !$NoCloud -or $Analyze ) {
    # Получаем список дисков, которые нужно обновить для текущего набора раздач.
    $disk_names = Get-DiskList $tracker_list
    # Получаем список существующих архивов.
    $done_list, $done_hashes = Get-Archives -Force -Name $disk_names
}

# Проверим указанные разделы и статус их выгрузки в облако.
if ( $Analyze ) {
    if ( !$tracker.groups ) {
        Write-Host ( 'Нет данных о раздачах в разделах: {0}' -f ($Forums -Join ",") )
    }
    Write-Host ( 'Получаем данные от клиента и анализируем разделы {0}' -f ($Forums -Join ",") ) -ForegroundColor Green

    # Получаем данные о завершённых раздачах клиента.
    $torrents_list = @{}
    Get-ClientTorrents | % { $torrents_list[ $_.hash ] = 1 }

    Write-Host ''
    Write-Host ( '| {0,6} | {1,-17} | {2,-25} | {3,-25} | {4,-25} |' -f 'Раздел', 'Всего раздач' , 'Уже есть в облаке', 'Есть в клиенте', 'Выгрузить из клиента' )
    $text = '| {0,6} | {1,6} [{2,8}] | {3,6} [{4,8}] ({5,3} %) | {6,6} [{7,8}] ({8,3} %) | {9,6} [{10,8}] ({11,-3} %) |'
    $tracker.groups.GetEnumerator() | Sort-Object -Property name | % {
        $tracker_list = $_.value
        $tracker_size = ( $tracker_list     | Measure-Object size -Sum ).Sum
        if ( $done_hashes ) {
            $arch_list   = @( $tracker_list | ? { $done_hashes[ $_.hash ] } )
            $arch_size   = ( $arch_list     | Measure-Object size -Sum ).Sum
        }
        if ( $torrents_list ) {
            $client_list = @( $tracker_list | ? { $torrents_list[ $_.hash ] } )
            $client_size = ( $client_list   | Measure-Object size -Sum ).Sum
        }
        if ( $done_hashes ) {
            $load_list   = @( $client_list  | ? { !$done_hashes[ $_.hash ] } )
            $load_size   = ( $load_list     | Measure-Object size -Sum ).Sum
        }

        $row = @(
            $_.key
            # Данные с форума
            $tracker_list.count
            ( Get-BaseSize $tracker_size -Precision 0 )
            # Существующие архивы в облаке
            $arch_list.count
            ( Get-BaseSize $arch_size -Precision 0 )
            [math]::Floor( $arch_list.count * 100 / $tracker_list.count )
            # Раздачи в клиенте
            $client_list.count
            ( Get-BaseSize $client_size -Precision 0 )
            [math]::Floor( $client_list.count * 100 / $tracker_list.count )
            # Раздачи в клиенте, которых нет в облаке
            $load_list.count
            ( Get-BaseSize $load_size -Precision 0 )
            [math]::Floor( $load_list.count * 100 / $tracker_list.count )

        )
        Write-Host ( $text -f $row )

        # Добавим незалитые раздачи в файл с завершёнными.
        $load_list | % { $_.hash } | Out-File $stash_folder.downloaded -Append
    }
    Exit
}


if ( $done_hashes ) {
    # Вычисляем раздачи, у которых нет архива в облаке.
    $tracker_list = @( $tracker_list | ? { !$done_hashes[ $_.hash ] } )
    Write-Host ( '- после исключения существущих архивов, осталось раздач: {0}.' -f $tracker_list.count )
}
if ( !$tracker_list ) { Exit }

# Определить категорию новых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) { $Category = 'temp' }

# Подключаемся к клиенту.
Write-Host 'Получаем список раздач из клиента..'
Initialize-Client

$torrents_list = @{}
$torrents_all = Get-ClientTorrents -Completed $false
$torrents_all | % { $torrents_list[ $_.hash ] = 1 }


if ( $torrents_list ) {
    # Исключаем раздачи, которые уже есть в клиенте.
    $tracker_list = @( $tracker_list | ? { !$torrents_list[ $_.hash ] } )
    Write-Host ( '- от клиента получено раздач: {0}, после их исключения, раздач осталось: {1}.' -f $torrents_list.count, $tracker_list.count )
}
if ( !$tracker_list ) { Exit }


# Текущее количество и объём раздач в клиенте выбранной категории.
$current = 1
$torrents_cat = @( $torrents_all | ? { $_.category -eq $Category } )
$current_total = $torrents_cat.count
[long]$current_size = ( $torrents_cat | Measure-Object size -Sum ).Sum

$added = 0
[long]$added_size = 0

# Добавленый объём раздач за этот запуск коллектора.
[long]$SizeLimit = ($SizeLimit * 1gb) # Гб
# Общий возможный занятый объём раздачами. Если не задан в параметрах вызова, берём настройку из скрипта.
[long]$SizeTotal = if ( $SizeTotal ) { $SizeTotal * 1gb } else { $collector.collect_size }
if ( !$TopicsTotal ) { $TopicsTotal = $collector.collect_count }


if ( $First ) {
    Write-Host ( '- будет добавлено первых {0} раздач.' -f $First ) -ForegroundColor DarkCyan
}
if ( $SizeLimit ) {
    Write-Host ( '- будет добавлено первые {0} раздач.' -f (Get-BaseSize $SizeLimit ) ) -ForegroundColor DarkCyan
}
if ( $TopicsTotal ) {
    Write-Host ( '- общий лимит количества раздач: {0}.' -f $TopicsTotal ) -ForegroundColor DarkCyan
}
if ( $SizeTotal ) {
    Write-Host ( '- общий лимит объёма раздач {0}.' -f ( Get-BaseSize $SizeTotal) ) -ForegroundColor DarkCyan
}

# Сортируем по заданному полю (size по-умолчанию).
$tracker_list = @( $tracker_list | Sort-Object -Property @{Expression = $Sort; Descending = $Descending} )

if ( $DryRun ) { Exit }

# Авторизуемся на форуме
Write-Host ''
Initialize-Forum

Write-Host ''
Write-Host ( '[collect][{0:t}] Начинаем перебирать раздачи.' -f (Get-Date) ) -ForegroundColor Green
foreach ( $torrent in $tracker_list ) {
    # Проверяем общие лимиты коллектора.
    $errors = @()
    if ( $TopicsTotal -and $current_total -ge $TopicsTotal ) {
        $limit_text = '[limit] Общее количество раздач в клиенте [{0}]: {1}, больше допустимого {2}.'
        $errors += $limit_text -f $client.name, $current_total, $TopicsTotal
    }
    if ( $SizeTotal -and $current_size -ge $SizeTotal ) {
        $limit_text = '[limit] Занятый объём раздач в клиенте [{0}]: {1}, больше допустимого {2}.'
        $errors += $limit_text -f $client.name, (Get-BaseSize $current_size), (Get-BaseSize $SizeTotal)
    }
    if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Break; }


    $ProgressPreference = 'Continue'
    $perc = [math]::Round( $current * 100 / $tracker_list.count )
    $ActivityStatus = "всего: {0} из {1}, добавлено {2} ({3}), {4} %" -f $current, $tracker_list.count, $added, (Get-BaseSize $added_size), $perc
    Write-Progress -Activity 'Обрабатываем раздачи' -Status $ActivityStatus -PercentComplete $perc
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
    $zip_path = Get-TorrentPath $torrent_id $torrent_hash
    if ( !$NoCloud ) {
        $zip_test = Test-CloudPath $zip_path
        if ( $zip_test.result ) {
            Write-Host ( 'Раздача уже имеется в облаке {0}. Пропускаем.' -f $torrent_id )
            Continue
        }
    }

    # Путь хранения раздачи, с учётом подпапки.
    $extract_path = Get-TopicDownloadPath $collector $torrent_id

    # Скачиваем торрент с форума
    Write-Host ( 'Скачиваем торрент-файл раздачи {0} ({1}).' -f $torrent_id, (Get-BaseSize $torrent.size) )
    $torrent_file = Get-ForumTorrentFile $torrent_id

    # Добавляем раздачу в клиент.
    Write-Host ( 'Добавляем торрент-файл раздачи {0} в клиент.' -f $torrent_id )
    Add-ClientTorrent $torrent_hash $torrent_file.FullName $extract_path $Category $StartPaused > $null
    Remove-Item $torrent_file.FullName


    $added++
    $current_total++
    $added_size += $torrent.size
    $current_size += $torrent.size

    $errors = @()
    # Проверяем лимиты на запуск.
    if ( $First -and $added -ge $First ) {
        $errors += '[limit] Заданный лимит ({1}) добавленных раздач выполнен. Количество: {0}.' -f $added, $First
    }
    if ( $SizeLimit -and $added_size -ge $SizeLimit ) {
        $errors += '[limit] Заданный лимит ({1}) добавленных раздач выполнен. Размер: {0}.' -f (Get-BaseSize $added_size), (Get-BaseSize $SizeLimit)
    }

    if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Break; }
    Start-Sleep -Seconds 1
} # end foreach

Write-Host ''
$text_total = '[collect][{0:t}] Раздач добавлено {1} ({2}). Всего в клиенте раздач с категорией [{3}]: {4} ({5})'
Write-Host ( $text_total -f (Get-Date), $added, (Get-BaseSize $added_size), $Category, $current_total, (Get-BaseSize $current_size) ) -ForegroundColor Green
