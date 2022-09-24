function Sync-Settings {
    if ($nul -eq $client_url ) { return $false }
    else { return $true }
}

function Get-Archives ( $google_folders ) { 
    $google_folder = $google_folders[0]
    $dones = @{}
    ( get-childitem( $google_folder ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem( $_ ) } | ForEach-Object { $dones[$_.BaseName.ToLower()] = 1 }
    return $dones
}

function Initialize-Client {
    $logindata = "username=$webui_login&password=$webui_password"
    $loginheader = @{Referer = $client_url }
    Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul
    return $sid
}

function Get-ClientTorrents ($client_url, $sid, $t_args) {
    if ( $t_args.Count -eq 0) {
        $all_torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' ) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | sort-object -Property size
        $torrents_list = $all_torrents_list | Where-Object { $_.state -eq 'uploading' -or $_.state -eq 'pausedUP' -or $_.state -eq 'queuedUP' -or $_.state -eq 'stalledUP' }
        return $torrents_list
    }
    else {
        $reqdata = 'hashes=' + $t_args[0]
        $torrents_list = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info?' + $reqdata) -WebSession $sid ).Content | ConvertFrom-Json | Select-Object name, hash, content_path, save_path, state, size, category, priority | Where-Object { $_.state -ne 'downloading' -and $_.state -ne 'stalledDL' -and $_.state -ne 'queuedDL' -and $_.state -ne 'error' -and $_.state -ne 'missingFiles' } | sort-object -Property size
        return $torrents_list
    }
    
}

function Get-TopicIDs( $torrents_list ) {
    foreach ( $torrent in $torrents_list ) {
        $reqdata = 'hash=' + $torrent.hash
        try { $torprops = ( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/properties' ) -Body $reqdata  -WebSession $sid -Method POST ).Content | ConvertFrom-Json }
        catch { pause }
        $torrent.state = $nul
        if ( $torprops.comment -match 'rutracker' ) {
            $torrent.state = ( Select-String "\d*$" -InputObject $torprops.comment).Matches.Value
        }
        # если не удалось получить информацию об ID из коммента, сходим в API и попробуем получить там
        if ( $nul -eq $torrent.state ) {
            $torrent.state = ( ( Invoke-WebRequest ( 'http://api.rutracker.org/v1/get_topic_id?by=hash&val=' + $torrent.hash ) ).content | ConvertFrom-Json ).result.($torrent.hash)
        }
        # исправление путей для кривых раздач с одним файлом в папке
        if ( ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '')) -match ('[\\/]') ) {
            $separator = $matches[0]
            $torrent.content_path = $torrent.save_path + $separator + ( $torrent.content_path.Replace( $torrent.save_path.ToString(), '') -replace ('^[\\/]', '') -replace ('[\\/].*$', '') )
        }
    }
    $torrents_list = $torrents_list | Where-Object { $nul -ne $_.state }
    return $torrents_list
}

function Get-Required ( $torrents_list, $dones ) {
    $torrents_list_required = [System.Collections.ArrayList]::new()
    $torrents_list | ForEach-Object {
        if ( $_.state -ne '' -and $nul -eq $dones[( $_.state.ToString() + '_' + $_.hash.ToLower())] ) {
            $torrents_list_required += $_
        }
        elseif ( $delete_processed -eq 1 ) {
            $reqdata = 'hashes=' + $_.hash + '&deleteFiles=true'
            Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/delete' ) -Body $reqdata -WebSession $sid -Method POST > $nul
        }
    }
    return $torrents_list_required
}

function  Get-Compression ( $sections_compression, $default_compression, $torent ) {
    if ( -$nul -eq $default_compression ) { $compression = '1' }
    else {
        if ( $choice -eq '' -or $nul -eq $choice ) {
            $torrent.priority = ( ( Invoke-WebRequest ( 'http://api.rutracker.org/v1/get_tor_topic_data?by=hash&val=' + $torrent.hash ) ).content | ConvertFrom-Json -AsHashtable ).result[$torrent.state].forum_id
        }
        try { $compression = $sections_compression[$torrent.priority.ToInt32($nul)] } catch { }
        if ( $nul -eq $compression ) { $compression = $default_compression }
    }
    return $compression
}

function Get-TodayTraffic ( $uploads_all, $zip_size, $google_folder) { 
    $now = Get-date
    $daybefore = $now.AddDays( -1 )
    $uploads_tmp = @{}
    $uploads = $uploads_all[ $google_folder ]
    $uploads.keys | Where-Object { $_ -ge $daybefore } | ForEach-Object { $uploads_tmp += @{ $_ = $uploads[$_] } }
    $uploads = $uploads_tmp
    $uploads += @{ $now = $zip_size }
    $uploads_all[$google_folder] = $uploads
    $uploads_all | Export-Clixml -Path $upload_log_file
    return ( $uploads.values | Measure-Object -sum ).Sum, $uploads_all
}

function Start-Stopping { 
    $paused = $false
    while ( ( $nul -ne $start_time -and $nul -ne $stop_time ) -and `
        ( ( $start_time -lt $stop_time -and ( ( Get-Date -Format t ) -lt $start_time -or ( Get-Date -Format t ) -gt $stop_time ) ) -or `
            ( $start_time -gt $stop_time -and ( ( Get-Date -Format t ) -gt $stop_time -and ( Get-Date -Format t ) -lt $start_time ) )
        )
    ) {
        if ( -not $paused ) {
            Write-Output "Останавливаемся по расписанию, ждём до $start_time"
            $paused = $true
        }
        Start-Sleep -Seconds 60
        Write-Output ( Get-Date -Format t )
    }
}

function Convert-Size ( $size , $base = 1024) {
    return ( [math]::Round( $size / $base / $base / $base ) ).ToString()
}
