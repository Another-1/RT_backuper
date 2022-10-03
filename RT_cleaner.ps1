. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
If ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Clear-Host

$os, $folder_sep = Get-OsParams

$hashes = @{}
Get-Content $remove_log_file | Get-Unique | Sort-Object | % {
    $id, $hash = ( $_.Split('.')[0] ).Split('_')
    $hashes[ $hash ] = $id
}
Clear-Content -Path $remove_log_file

if ( $hashes.count -eq 0 ) {
    Write-Host ('Нет раздач для удаления.')
    Exit
}

Write-Host 'Авторизуемся в клиенте.'
$sid = Initialize-Client

$torrents_list = Get-ClientTorrents $client_url $sid $hashes.keys

if ( $torrents_list -eq $null ) {
    Write-Host ( 'Не удалось получить раздачи!' )
    Exit
}

Write-Host ( '..получено раздач: {0}.' -f $torrents_list.count )
foreach ( $torrent in $torrents_list ) {
    $hash = $torrent.hash

    Write-Host ( 'Пробуем удалить раздачу {0}' - $torrent.name )
    Delete-ClientTorrent $hashes[ $hash ] $hash $torrent.category
}
# end foreach

