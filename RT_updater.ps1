. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

Start-Pause
Start-Stopping

# Запускаем обновление списка архивов.
Sync-ArchList $args[0]
