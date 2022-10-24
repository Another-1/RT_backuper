. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

Start-Pause
Start-Stopping

# Запускаем обновление списка архивов.
Sync-ArchList $args[0]
