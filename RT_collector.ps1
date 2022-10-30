Param (
    [ValidateRange('Positive')][int[]]$Forums,
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
    $tracker_list = Get-ForumTopics -Topics $Topics
}
# Идем по обычной цепочке получения всех раздач раздела.
else {
    if ( !$Forums ) {
        $forum_id = Read-IntValue 'Введите раздел'
        if ( $forum_id ) { $Forums = @( $forum_id ) }
    }
    if ( !$Forums ) { Exit }

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

    $tracker_list = Get-ForumTopics -Forums $Forums

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
Write-Host 'Получаем список раздач из клиента..'
Initialize-Client
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
if ( !$Category ) { $Category = 'temp' }

# Сортируем по заданному полю (size по-умолчанию).
$tracker_list = $tracker_list | Sort-Object -Property @{Expression = $Sort; Descending = $Descending}

# Авторизуемся на форуме
Write-Host ''
Initialize-Forum

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

    # Проверка на переполнение каталога с загрузками.
    if ( $collector.collect_size ) {
        Compare-MaxSize $collector.collect $collector.collect_size
    }

    # Проверяем, наличие раздачи в облаке.
    $zip_path = Get-TorrentPath $torrent_id $torrent_hash
    Write-Host ( 'Проверяем гугл-диск {0}' -f $zip_path )
    $zip_test = Test-PathTimer $zip_path
    Write-Host ( '[check] Проверка выполнена за {0} сек, результат: {1}' -f $zip_test.exec, $zip_test.result )
    if ( $zip_test.result ) {
        Write-Host ( 'Раздача уже имеется в облаке {0}.' -f $torrent_id )
        Continue
    }

    # Путь хранения раздачи, с учётом подпапки.
    $extract_path = $collector.collect
    if ( $collector.sub_folder ) {
        $extract_path = $collector.collect + $OS.fsep + $torrent_id
    }

    # Скачиваем торрент с форума
    Write-Host ( 'Скачиваем торрент-файл раздачи {0} ({1}).' -f $torrent_id, (Get-BaseSize $torrent.size) )
    $torrent_file = Get-ForumTorrentFile $torrent_id

    # Добавляем раздачу в клиент.
    Write-Host ( 'Добавляем торрент-файл раздачи {0} в клиент.' -f $torrent_id )
    Add-ClientTorrent $torrent_hash $torrent_file.FullName $extract_path $Category > $null
    Remove-Item $torrent_file.FullName


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
