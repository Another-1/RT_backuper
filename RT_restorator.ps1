Param (
    [ValidateRange('Positive')][int[]]$Forums,
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
    $tracker_list = Get-ForumTopics -Topics $Topics
}
# Идем по обычной цепочке получения всех раздач раздела.
else {
    if ( !$Forums ) {
        $forum_id = Read-IntValue 'Введите раздел'
        if ( $forum_id ) { $Forums = @( $forum_id ) }
    }
    if ( !$Forums ) { Exit }

    $tracker_list = Get-ForumTopics -Forums $Forums

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
$done_list, $done_hashes = Get-Archives

# Вычисляем раздачи, у которых есть архив в облаке.
$tracker_list = $tracker_list | ? { $done_hashes[ $_.hash ] }
Write-Host ( 'Имеется архивов в облаке: {0}.' -f $tracker_list.count )


# Подключаемся к клиенту, получаем список существующих раздач.
Write-Host 'Получаем список раздач из клиента..'
Initialize-Client

$torrents_list = @{}
Get-ClientTorrents -Completed $false | % { $torrents_list[ $_.hash ] = 1 }
if ( $torrents_list ) {
    # Исключаем раздачи, которые уже есть в клиенте.
    $tracker_list = $tracker_list | ? { !$torrents_list[ $_.hash ] }
    Write-Host ( 'От клиента [{0}] получено раздач: {1}. Раздач доступных к восстановлению: {2}.' -f $client.name, $torrents_list.count, $tracker_list.count )
}

# Определить категорию добавляемых раздач.
if ( !$Category ) { $Category = $collector.category }
if ( !$Category ) { $Category = 'restored' }

# Авторизуемся на форуме
Write-Host ''
Initialize-Forum

Write-Host 'Перебираем раздачи'
foreach ( $torrent in $tracker_list ) {
    # Ид и прочие параметры раздачи.
    $torrent_id   = $torrent.topic_id
    $torrent_hash = $torrent.hash.ToLower()
    if ( !$torrent_id ) {
        Write-Host '[skip] Отсутсвует ид раздачи. Пропускаем.'
        Continue
    }

    # Проверяем, наличие раздачи в облаке.
    $zip_path = Get-TorrentPath $torrent_id $torrent_hash
    Write-Host ( 'Проверяем гугл-диск {0}' -f $zip_path )
    $zip_test = Test-PathTimer $zip_path
    Write-Host ( '[check] Проверка выполнена за {0} сек, результат: {1}' -f $zip_test.exec, $zip_test.result )
    if ( !$zip_test.result ) {
        Write-Host '[skip] Не удалось найти архив для раздачи в облаке. Пропускаем.'
        Continue
    }

    # Путь хранения раздачи, с учётом подпапки.
    $extract_path = $collector.collect
    if ( $collector.sub_folder ) {
        $extract_path = $collector.collect + $OS.fsep + $torrent_id
    }

    Write-Host "Распаковываем $zip_path"
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

    Write-Host ( 'Скачиваем торрент-файл раздачи {0} ({1}).' -f $torrent_id, (Get-BaseSize $torrent.size) )
    $torrent_file = Get-ForumTorrentFile $torrent_id

    # Добавляем раздачу в клиент.
    Write-Host ( 'Добавляем торрент для раздачи {0} в клиент.' -f $torrent_id )
    Add-ClientTorrent $torrent_hash $torrent_file.FullName $extract_path $Category > $null
    Remove-Item $torrent_file.FullName

    Start-Sleep -Seconds 1
}
