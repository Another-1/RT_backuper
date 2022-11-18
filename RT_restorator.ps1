Param (
    [ValidateRange('Positive')][int[]]$Forums,
    [ValidateRange('Positive')][int[]]$Topics,
    [ValidateSet(0, 1, 2)][string]$Priority = -1,
    [string]$Category,
    [switch]$DryRun,
    [switch]$Verbose,

    [ArgumentCompleter({ param($cmd, $param, $word) [array](Get-Content "$PSScriptRoot/clients.txt") -like "$word*" })]
    [string]
    $UsedClient
)

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

if ( !$collector.collect ) {
    $collector.collect = Get-ClientDownloadDir
}
if ( !$collector.collect ) {
    Write-Host 'Каталог хранения раздач ($collector.collect) не задан.'
    Exit
}
New-Item -ItemType Directory -Path $collector.collect -Force > $null

# Если передан список раздач. работаем с ними.
if ( $Topics.count ) {
    $tracker = Get-ForumTopics -Topics $Topics
    $tracker_list = $tracker.topics
}
# Идем по обычной цепочке получения всех раздач раздела.
else {
    if ( !$Forums ) {
        $forum_id = Read-IntValue 'Введите раздел'
        if ( $forum_id ) { $Forums = @( $forum_id ) }
    }
    if ( !$Forums ) { Exit }

    $tracker = Get-ForumTopics -Forums $Forums
    $tracker_list = $tracker.topics

    # Если задан приоритет, фильтруем.
    if ( $Priority -ge 0 ) {
        $tracker_list = @( $tracker_list | ? { $_.priority -eq $Priority } )
    }
}

if ( !$tracker_list ) {
    Write-Host 'По заданным фильтрам не получено ни одной раздачи.' -ForegroundColor Green
    Exit
}
Write-Host ( 'После фильтрации осталось раздач: {0}.' -f $tracker_list.count )

# Получаем список дисков, которые нужно обновить для текущего набора раздач.
$disk_names = Get-DiskList $tracker_list
# Получаем список существующих архивов.
$done_list, $done_hashes = Get-Archives -Force -Name $disk_names

# Вычисляем раздачи, у которых есть архив в облаке.
$tracker_list = @( $tracker_list | ? { $done_hashes[ $_.hash ] } )
Write-Host ( 'Имеется архивов в облаке: {0}.' -f $tracker_list.count )

# Подключаемся к клиенту, получаем список существующих раздач.
Write-Host 'Получаем список раздач из клиента..'
Initialize-Client

$torrents_list = @{}
Get-ClientTorrents -Completed $false | % { $torrents_list[ $_.hash ] = 1 }
if ( $torrents_list ) {
    # Исключаем раздачи, которые уже есть в клиенте.
    $tracker_list = @( $tracker_list | ? { !$torrents_list[ $_.hash ] } )
    Write-Host ( 'От клиента [{0}] получено раздач: {1}. Раздач доступных к восстановлению: {2}.' -f $client.name, $torrents_list.count, $tracker_list.count )
}

if ( !$tracker_list ) { Exit }

# Определить категорию добавляемых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) { $Category = 'restored' }

# Авторизуемся на форуме
Write-Host ''
Initialize-Forum

Write-Host ( '[restore][{0:t}] Начинаем перебирать раздачи.' -f (Get-Date) )
foreach ( $torrent in $tracker_list ) {
    # Ид и прочие параметры раздачи.
    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash.ToLower()
    if ( !$torrent_id ) {
        Write-Host '[skip] Отсутсвует ид раздачи. Пропускаем.'
        Continue
    }

    # Проверяем, наличие раздачи в облаке.
    $zip_google_path = Get-TorrentPath $torrent_id $torrent_hash
    $zip_test = Test-CloudPath $zip_google_path
    if ( !$zip_test.result ) {
        Write-Host ( '[skip] Нет архива для раздачи {0} в облаке. Пропускаем.' -f $torrent_id ) -ForegroundColor Yellow
        Continue
    }
    if ( $DryRun ) { Exit }

    # Путь хранения раздачи, с учётом подпапки.
    $extract_path = Get-TopicDownloadPath $torrent_id

    Write-Host "Распаковываем $zip_google_path"
    Restore-ZipTopic $zip_google_path $extract_path
    if ( $LastExitCode -ne 0 ) {
        Write-Host ( '[check] Ошибка распаковки архива, код ошибки: {0}.' -f $LastExitCode )
        Continue
    }

    Write-Host ( 'Скачиваем торрент-файл раздачи {0} ({1}).' -f $torrent_id, (Get-BaseSize $torrent.size) )
    $torrent_file = Get-ForumTorrentFile $torrent_id

    # Добавляем раздачу в клиент.
    Write-Host ( 'Добавляем торрент для раздачи {0} в клиент.' -f $torrent_id )
    Add-ClientTorrent $torrent_hash $torrent_file.FullName $extract_path $Category > $null
    Remove-Item $torrent_file.FullName

    Start-Sleep -Seconds 1
}
# end foreach
