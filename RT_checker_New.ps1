$logindata = "username=admin&password=mainstreet"
$loginheader = @{Referer = 'http://192.168.0.232:8082' }

$save_disks = @( 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'L', 'N' )
$real_files = [System.Collections.ArrayList]::new()
foreach ( $save_disk in $save_disks ) {
    $path = $save_disk + ':\Хранимое'
    Write-output ( 'Scanning real files in ' + $path )
    Get-ChildItem -LiteralPath $path -recurse -Attributes !Directory -Exclude '*.!qb' | Select-Object -ExpandProperty FullName | ForEach-Object { [void]$real_files.Add( $_) }
}

Write-Output 'Getting torrents info'
Invoke-WebRequest -Headers $loginheader -Body $logindata http://192.168.0.232:8082/api/v2/auth/login -Method POST -SessionVariable sid > $nul
$torrents_list = ( Invoke-WebRequest -uri http://192.168.0.232:8082/api/v2/torrents/info -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, content_path, state, hash

$paths = @{}
$comments = @{}
$names = @{}
$files_all = @{}
$cnt = 0
foreach ( $torrent in $torrents_list ) {
    $cnt++
    $torrent.content_path = $torrent.content_path -replace ( '\\$', '')
    try {
        $paths += @{ $torrent.content_path = $torrent.hash }
    }
    catch {
        if ($torrent.content_path[0] -ne 'K') {
            Write-Output $torrent.content_path
            Pause
        }
    }
    try {
        $names += @{ $torrent.name = $torrent.hash }
    }
    catch {
        Write-Output $torrent.name
        Pause
    }
    try { Write-Progress -Activity "Getting expected files" -Status "$cnt раздач окучено" -PercentComplete ( $cnt * 100 / $torrents_list.Count) }
    catch {}
    $reqdata = 'hash=' + $torrent.hash
    $torprops = ( Invoke-WebRequest -uri http://192.168.0.232:8082/api/v2/torrents/properties -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json
    try {
        $comments += @{ $torprops.comment = $torrent.name }
    }
    catch {
        Write-Output $torprops.comment
        Write-Output $torrent.name
        Write-Output $comments[$torprops.comment]
        # Pause
    }
    $torfiles = ( Invoke-WebRequest -uri http://192.168.0.232:8082/api/v2/torrents/files -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json
    $torfiles | ForEach-Object { 
        try {
            $files_all[ ( $torprops.save_path + '\' + $_.name.Replace( '/', '\' ) ).Replace('\\', '\' ) ] = 1
        }
        catch {
            Write-Output ( $torprops.save_path + '\' + $_.name.Replace( '/', '\' ) ).Replace('\\', '\' )
            # pause
        }
    }
    $not_reg = ( Invoke-WebRequest -uri http://192.168.0.232:8082/api/v2/torrents/trackers -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json | Where-Object { $_.status -eq 4 -and $_.msg -eq 'Torrent not registered'}
    if ( $null -ne $not_reg ){
        Write-Output ( $torrent.name + ' ' + $torprops.comment + ' not registered' )
    }
}
Write-Output 'Checking for excess files'
$real_files | Where-Object { $nul -eq $files_all[ $_] }
Write-Output 'Checking for excess files complete.'
Pause