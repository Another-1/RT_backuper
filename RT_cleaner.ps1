. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Clear-Host
Start-Pause
Start-Stopping

$os, $folder_sep = Get-OsParams

$step = 10
$file_path = $stash_folder.finished
$file = Watch-FileExist $file_path


$total = Get-Content $file_path | Sort-Object -Unique
$total_count = $total.count

Write-Host ( '[cleaner] Обнаружено раздач: {0}.' -f $total_count )
if ( $total_count -eq 0 ) {
    Exit
}

$runs = [math]::Ceiling( $total_count / $step )

Write-Host '[cleaner] Авторизуемся в клиенте.'
try {
    $sid = Initialize-Client
} catch {
    Write-Host ( 'Авторизация не удалась. {0}' -f $Error[0] ) -ForegroundColor Red
    Exit
}

Write-Host ( 'Начинаем обработку. Потребуется итераций {0}.' -f $runs )
For ( $i = 1; $i -le $runs; $i++ ) {
    $percent = $i*100 / $runs

    $selected = Get-FileFirstContent $file_path $step

    $hashes = @{}
    $selected | % { $id, $hash = ( $_.Split('.')[0] ).Split('_'); $hashes[$hash] = $id }

    Write-Host ( 'Итерация {0}/{1}, раздач {2}, опрашиваем клиент.' -f $i, $runs, $hashes.count )
    $torrents = Get-ClientTorrents $client_url $sid $hashes.keys
    if ( !$torrents ) {
        Write-Host ( 'Не найдены раздачи в клиенте. Пропускаем.' )
        Continue
    }

    foreach ( $torrent in $torrents ) {
        $id = $hashes[$torrent.hash]

        $disk_id, $disk_name, $disk_path = Get-DiskParams $id
        $archive = $stash_folder.archived + $folder_sep + $disk_name + '.txt'

        ($id.ToString() + '_' + $torrent.hash.ToLower()) | Out-File $archive -Append

        Write-Host ( '[cleaner] Пробуем удалить раздачу {0}, {1}' -f $id, $torrent.name )
        Delete-ClientTorrent $id $torrent.hash $torrent.category
    }
}
# end foreach

Write-Host ( 'Обработано {0} раздач.' -f $total_count )


# После добавления раздач в списки, пересортируем их.
Write-Progress -Activity "Сортируем списки.." -CurrentOperation "Обработка.."
$archives = Get-ChildItem $stash_folder.archived -File -Filter ($google_folder_prefix + '*.txt') | ? { $_.Size }
$i = 0
foreach ( $arch in $archives ) {
    $content = Get-Content $arch.FullName
    Write-Progress -Activity "Сортируем списки.." -Status ("Сортируем [{0}] {1} шт." -f $arch.BaseName, $content.count) -PercentComplete ($i++ * 100 / $archives.count)
    $content | Sort-Object -Unique | Out-File $arch.FullName
}
