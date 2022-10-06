. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Clear-Host

$os, $folder_sep = Get-OsParams

$step = 10
$file_path = $stash_folder.finished
$file = Watch-FileExist $file_path


$total = Get-Content $file_path | Get-Unique
$total_count = $total.count

Write-Host ( '[cleaner] Обнаружено раздач: {0}.' -f $total_count )
if ( $total_count -eq 0 ) {
    Exit
}

$runs = [math]::Ceiling( $total_count / $step )

Write-Host 'Авторизуемся в клиенте.'
$sid = Initialize-Client

For ( $i = 1; $i -le $runs; $i++ ) {
    $percent = $i*100 / $runs
    Write-Progress -Activity "[cleaner] Обрабатываем, итерация: $i" -status "Собираем данные.." -percentComplete $percent

    # Вытаскиваем данные из файла.
    $all_file = Get-Content $file_path | Get-Unique
    # Вытаскиваем первые N строк
    $selected = $all_file | Select -First $step
    # Остальное записываем обратно
    $all_file | Select-Object -Skip $step | Out-File $file_path


    $hashes = @{}
    $selected | % { $id, $hash = ( $_.Split('.')[0] ).Split('_'); $hashes[$hash] = $id }

    Write-Progress -Activity ("[cleaner] Обрабатываем, итерация: " + $i*$step) -status "Опрашиваем клиент.." -percentComplete $percent
    $torrents = Get-ClientTorrents $client_url $sid $hashes.keys
    if ( !$torrents ) {
        Write-Progress -Activity ("[cleaner] Обрабатываем, итерация: " + $i*$step) -status "Раздачи не найдены. Пропускаем." -percentComplete $percent
        Continue
    }

    foreach ( $torrent in $torrents ) {
        $id = $hashes[$torrent.hash]


        $disk_id, $disk_name, $disk_path = Get-DiskParams $id
        $archive = $stash_folder.archived + $folder_sep + $disk_name + '.txt'

        ($id.ToString() + '_' + $torrent.hash.ToLower()) | Out-File $archive -Append
        Exit

        Write-Host ( '[cleaner] Пробуем удалить раздачу {0}, {1}' -f $id, $torrent.name )
        Delete-ClientTorrent $id $torrent.hash $torrent.category
    }
}
# end foreach

Write-Host ( 'Обработано {0} раздач.' -f $total_count )
