. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Clear-Host
Start-Pause
Start-Stopping

$os, $folder_sep = Get-OsParams

Sync-ArchList
