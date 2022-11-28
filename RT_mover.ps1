param (
    [Alias("src")] [string]$disk_from,
    [ArgumentCompleter({ param($cmd, $param, $word) [array]( Get-Content "$PSScriptRoot/clients.txt" ) })]
    [Alias("scl")][string]$client_from = 'NAS-2',
    [ArgumentCompleter({ param($cmd, $param, $word) [array]( Get-Content "$PSScriptRoot/clients.txt" ) })]
    [Alias("dcl")][string]$client_to = 'NAS',
    [switch]$NoClient = $true
)

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

$client = Select-Client $client_from
Initialize-Client

$torrents_list = Get-ClientTorrents | Where-Object { $_.content_path -match '^\\' } | ForEach-Object {
    foreach ( $key in $mover.keys ) {
        if ( $_.content_path -match $key ) { $_ ; break }
    }
}
$torrents_list = Get-TopicIDs $torrents_list $null

$client = Select-Client $client_to
Initialize-Client
Initialize-Forum
$torrents_list | ForEach-Object {
    $torrent_file = Get-ForumTorrentFile $_.topic_id
    $move_path = $_.save_path
    foreach ( $key in $mover.keys ) {
        if ( $move_path -match $key ) { $move_path = $move_path -replace ( ".*$key", $mover[$key] ); break }
    }
    Write-Host ( '[mover] Подхватываем ' + $_.name + ' в ' + $client.name + ', ' + $move_path )
    $client = Select-Client $client_to
    Add-ClientTorrent $_.hash $torrent_file.FullName $move_path $_.Category > $null
    $client = Select-Client $client_from
    Remove-ClientTorrent $_.topic_id $_.hash
    Remove-Item $torrent_file.FullName
    Start-Sleep -Seconds 1
}