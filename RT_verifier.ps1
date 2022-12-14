. "$PSScriptRoot\RT_settings_my.ps1"

if ($client_url -eq '' -or $nul -eq $client_url ) {
    Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'
    Pause
    exit
}
if ( $PSVersionTable.OS.ToLower().contains('windows')) {
    $separator = '\'
}
else {
    $separator = '/'
}
Write-Host 'Смотрим, что уже заархивировано'
$dones = (( get-childitem( $google_folders[0] ) | Where-Object { $_.name -like 'ArchRuT*' } ) | ForEach-Object { Get-ChildItem $_ -Filter '*.7z' | Select-Object BaseName, FullName, Length })

Write-Host 'Скачиваем TAR с деревом трекера'
$tmp_path = $PSScriptRoot + $separator + 'tmp3'
New-Item -Path $tmp_path -ItemType Directory -ErrorAction SilentlyContinue
Remove-Item ( $tmp_path + $separator + 'f-all.tar' ) -Force -ErrorAction SilentlyContinue
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest https://api.t-ru.org/v1/static/pvc/f-all.tar -OutFile ( $tmp_path + $separator + 'f-all.tar' )
$ProgressPreference = 'Continue'
Write-Progress -Completed -Activity 'Web request status' -Status 'Ready'
Set-Location $tmp_path
Write-Host 'Достаём из TAR архивы GZ'
Remove-Item *.gz -Force -ErrorAction SilentlyContinue
tar xvf ( $tmp_path + $separator + 'f-all.tar' ) | Out-Null
Write-Host 'Удаляем TAR'
Remove-Item ( $tmp_path + $separator + 'f-all.tar' ) -Force -ErrorAction SilentlyContinue
Write-Host 'Распаковываем архивы GZ'
Remove-Item *.json  -Force -ErrorAction SilentlyContinue
Get-Item *.json.gz | ForEach-Object { & $7z_path x $_ } | Out-Null
Write-Host 'Удаляем архивы GZ'
Remove-Item *.gz -Force
Write-Host 'Парсим JSON-ы'
$all_torrents_list = @{}
Get-Item *.json | foreach-object { ( Get-Content $_ | ConvertFrom-Json -AsHashtable ).result.getenumerator() | Where-Object { $null -ne $_.Name } | `
        ForEach-Object { $all_torrents_list[$_.Name] = @($_.Value[3], $_.Value[7]) } }
Write-Host 'Удаляем JSON-ы'
# Remove-Item *.json -Force
Set-Location $PSScriptRoot

$i = 0
ForEach ( $done in $dones ) {
    $i++
    Write-Progress -Activity 'Проверяем' -Status ( $done.BaseName + '.7z, ' + $done.Length ) -PercentComplete ( ( $i * 100 / $dones.count ) + 1 )
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
    if ( $nul -eq ( $res | select-string 'Everything is Ok' ) ) {
        if ( $nul -ne ( $res | select-string 'Data Error' ) ) {
            Write-Host ( $done.FullName + ' битый' ); continue 
        }
        else {
            Write-Host ( 'C архивом' + $done.FullName + ' что-то непонятное' ); continue 
        }
    }
    if (((( $res | Select-String '^Size' ).ToString()) -replace ('^\D*','')).ToInt64( $nul ) -lt $all_torrents_list[$spl[0]][0] ) {
        Write-Host ( $done.FullName + ' слишком маленький')
        continue
    }

}
