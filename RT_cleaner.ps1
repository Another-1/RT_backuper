Param (
    [switch]$Verbose,
    [switch]$NoClient = $true
)

function Clear-ClientDownloads ( $zip_list ) {
    $step = 30
    $finished_list = $stash_folder.finished_list
    Watch-FileExist $finished_list > $null

    $total = Get-Content $finished_list | Sort-Object -Unique
    $total_count = $total.count

    if ( !$total_count ) { return }

    # Подключаемся к клиенту.
    Initialize-Client

    $deleted = 0
    $runs = [math]::Ceiling( $total_count / $step )
    For ( $i = 1; $i -le $runs; $i++ ) {
        $selected = Get-FileFirstContent $finished_list $step

        $selected = @( $selected | ? { $_ -notin $zip_list } )
        $hashes = @{}
        $selected | % { [int]$id, $hash = ( $_.Split('.')[0] ).Split('_'); if ($id) {$hashes[$hash] = $id} }
        $selected = $null
        if ( !$hashes.count ) { Continue }

        Write-Host ( 'Итерация {0}/{1}, раздач {2}, опрашиваем клиент.' -f $i, $runs, $hashes.count )
        $torrents = Get-ClientTorrents $hashes.keys
        # Выбираем только раздачи подходящей категории.
        $torrents = @( $torrents | ? { $_.category -in $uploader.delete_category } )
        if ( !$torrents ) {
            Write-Host ( 'Нет раздач, которые требуется удалить. Пропускаем.' )
            Continue
        }

        foreach ( $torrent in $torrents ) {
            $torrent_id = $hashes[$torrent.hash]
            # Собираем имя и путь хранения архива раздачи.

            Write-Host ( '[cleaner] Проверяем раздачу {0}, {1}' -f $torrent_id, $torrent.name )
            $zip_google_path = Get-TorrentPath $torrent_id $torrent.hash
            $zip_test = Test-CloudPath $zip_google_path
            # Если в облаке раздача есть, то её можно смело удалять из клиента
            if ( $zip_test.result ) {
                $deleted++
                Write-Host ( '[cleaner] Удаляем {0}, {1}' -f $torrent_id, $torrent.name )
                Remove-ClientTorrent $torrent_id $torrent.hash
            } else {
                Write-Host ( '[cleaner] Раздачи ещё нет в облаке, пропускаем {0}, {1}' -f $torrent_id, $torrent.name )
                Dismount-ClientTorrent $torrent_id $torrent.hash
            }
            Start-Sleep 1
        }
    }
    # end foreach

    Write-Host ( 'Для клиента {0} раздач обработано: {1}, удалено: {2}.' -f $cl.name, $total_count, $deleted ) -ForegroundColor Green
}

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

$ScriptName = (Get-Item $PSCommandPath).BaseName

$errors = @()
if ( !$used_modules.cleaner ) {
    $errors += 'Вы запустили {0}, хотя он не включён в настройках. Проверьте настройки $used_modules.' -f $ScriptName
}
if ( !$uploader.delete ) {
    $errors += '[cleaner] Опция удаления раздач выключена. Если вы хотите удалять обработанные раздачи, сперва включите.'
}
if ( !$uploader.delete_category ) {
    $errors += '[cleaner] Не указана категория раздач, которые следует удалять.'
}
if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Pause; Exit }

Start-Pause
Start-Stopping

if ( !$client_list ) {
    $client_list = @( $client )
}

# Найдём архивы, которые ожидают выгрузки.
$zip_list = Get-ChildItem $def_paths.finished -Filter '*.7z' | % { $_.BaseName }

foreach ( $cl in $client_list ) {
    Write-Host ''
    Write-Host ( '[cleaner] Подключаемся к торрент-клиенту "{0}", ищем раздачи, которые следует удалить из него.' -f $cl.name ) -ForegroundColor DarkCyan
    # Подключаемся к выбранному клиенту.
    $client = Select-Client $cl.name
    . (Connect-Client)

    # Ищем и удаляем раздачи.
    Clear-ClientDownloads $zip_list
}

# Очистим папку загрузок, если закачка происходит с учётом ид раздачи.
if ( $collector -and $collector.sub_folder ) {
    Start-Sleep 5
    Clear-EmptyFolders $collector.collect
}
