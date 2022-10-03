. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Clear-Host

$os, $folder_sep = Get-OsParams

$hashes = Get-Content $remove_log_file | Get-Unique | Sort-Object
Clear-Content $remove_log_file

Write-Host ( 'Обнаружено раздач: {0}.' -f $hashes.count )
if ( $hashes.count -eq 0 ) {
    Write-Host ('Нет раздач для удаления.')
    Exit
}

Write-Host 'Авторизуемся в клиенте.'
$sid = Initialize-Client

$hashes | % {
    $id, $hash = ( $_.Split('.')[0] ).Split('_')
    $torrent = Get-ClientTorrents $client_url $sid @($hash)

    Write-Host ( 'Пробуем удалить раздачу {0}, {1}' -f $id, $torrent.name )
    Delete-ClientTorrent $id $hash $torrent.category
}
# end foreach
