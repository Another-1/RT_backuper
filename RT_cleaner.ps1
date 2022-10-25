. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

Start-Pause
Start-Stopping

$errors = @()
if ( !$used_modules.cleaner ) {
    $errors += '[cleaner] Модуль отключён. Если вы хотите его использовать, сперва включите.'
}

if ( !$uploader.delete ) {
    $errors += '[cleaner] Опция удаления раздач выключена. Если вы хотите удалять обработанные раздачи, сперва включите.'
}
if ( !$uploader.delete_category ) {
    $errors += '[cleaner] Не указана категория раздач, которые следует удалять.'
}
if ( $errors ) {
    Write-Host ''
    $errors | Write-Host -ForegroundColor Yellow
    Exit
}

$step = 20
$finished_list = $stash_folder.finished_list -f $client.name
Watch-FileExist $finished_list > $null

$total = Get-Content $finished_list | Sort-Object -Unique
$total_count = $total.count

Write-Host ( '[cleaner] Обнаружено раздач: {0}.' -f $total_count )
if ( $total_count -eq 0 ) {
    Exit
}

# Подключаемся к клиенту.
Initialize-Client

$runs = [math]::Ceiling( $total_count / $step )
Write-Host ( 'Начинаем обработку. Потребуется итераций {0}.' -f $runs )
For ( $i = 1; $i -le $runs; $i++ ) {
    $selected = Get-FileFirstContent $finished_list $step

    $hashes = @{}
    $selected | % { $id, $hash = ( $_.Split('.')[0] ).Split('_'); $hashes[$hash] = $id }

    Write-Host ( 'Итерация {0}/{1}, раздач {2}, опрашиваем клиент.' -f $i, $runs, $hashes.count )
    $torrents = Get-ClientTorrents $hashes.keys
    # Выбираем только раздачи подходящей категории.
    $torrents = $torrents | ? { $_.category -eq $uploader.delete_category }
    if ( !$torrents ) {
        Write-Host ( 'Не найдены раздачи в клиенте. Пропускаем.' )
        Continue
    }

    foreach ( $torrent in $torrents ) {
        $id = $hashes[$torrent.hash]

        Write-Host ( '[cleaner] Пробуем удалить раздачу {0}, {1}' -f $id, $torrent.name )
        Remove-ClientTorrent $id $torrent.hash
        Start-Sleep 1
    }
}
# end foreach

Write-Host ( 'Обработано {0} раздач.' -f $total_count )

Start-Sleep 5
# Очистим папку загрузок, если закачка происходит с учётом ид раздачи.
if ( $collector.sub_folder ) {
    Clear-EmptyFolders $collector.collect
}
