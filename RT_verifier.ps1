. "$PSScriptRoot\RT_settings_my.ps1"

if ($client_url -eq '' -or $nul -eq $client_url ) {
    Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'
    Pause
    exit
}
if ( $PSVersionTable.OS.ToLower().contains('windows')) {
    $separator = '\'
    # $drive_separator = ':\'
}
else {
    $separator = '/'
    # $drive_separator = '/'
}
Write-Host 'Смотрим, что уже заархивировано'
$dones = (( get-childitem( $google_folders[0] ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem $_ -Filter '*.7z' | Select-Object BaseName, FullName })

Write-Host 'Getting TAR'
$tmp_path = $PSScriptRoot + $separator + 'tmp3'
New-Item -Path $tmp_path -ItemType Directory -ErrorAction SilentlyContinue
Remove-Item ( $tmp_path + $separator + 'f-all.tar' ) -Force -ErrorAction SilentlyContinue
Invoke-WebRequest https://api.t-ru.org/v1/static/pvc/f-all.tar -OutFile ( $tmp_path + $separator + 'f-all.tar' )
Set-Location $tmp_path
Write-Host 'Unpacking TAR'
Remove-Item *.gz -Force -ErrorAction SilentlyContinue
tar xvf ( $tmp_path + $separator + 'f-all.tar' ) | Out-Null
Remove-Item ( $tmp_path + $separator + 'f-all.tar' ) -Force -ErrorAction SilentlyContinue
Clear-Host
Write-Host 'Unpacking GZips'
Remove-Item *.json  -Force -ErrorAction SilentlyContinue
Get-Item *.json.gz | ForEach-Object { & $7z_path x $_ } | Out-Null
Write-Host 'Deleting GZips'
Remove-Item *.gz -Force
Write-Host 'Processing JSONs'
$all_torrents_list = @{}
Get-Item *.json | foreach-object { ( Get-Content $_ | ConvertFrom-Json -AsHashtable ).result.getenumerator() | Where-Object { $null -ne $_.Name } | `
        ForEach-Object { $all_torrents_list[$_.Name] = @($_.Value[3], $_.Value[7]) } }
Write-Host 'Deleting JSONs'
# Remove-Item *.json -Force
Set-Location $PSScriptRoot

ForEach ( $done in $dones ) {
    $spl = $done.BaseName -split '_'
    try {
        if ( $all_torrents_list[$spl[0]][1] -ne $spl[1] ) {
            Write-Host ( $done.FullName + ' устарел' )
            Continue
        }
    }
    catch {
        Write-Host ( $done.FullName + ' лишний')
        Continue
    }
    $res = ( & $7z_path t $done.FullName "-p20RuTracker.ORG22" )
    if ( $nul -eq $res | select-string 'Everything is Ok' ) {
        Write-Host ( 'Похоже, ' + $done.FullName + ' битый')
    }
    if ( ( ( ( $res | Select-String 'Physical Size' ).ToString() -replace 'Physical Size = ', '' ).Toint64($nul) * 1.1 ) -lt $all_torrents_list[$spl[0]][0] ) {
        Write-Host ( $done.FullName + ' подозрительно мал')
    }

}
