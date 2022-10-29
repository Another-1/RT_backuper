Param (
    [switch]$NoClient = $true
)

function Clear-ClientDownloads {
    $step = 30
    $finished_list = $stash_folder.finished_list
    Watch-FileExist $finished_list > $null

    $total = Get-Content $finished_list | Sort-Object -Unique
    $total_count = $total.count

    Write-Host ( '[cleaner] Обнаружено раздач: {0}.' -f $total_count )
    if ( $total_count -eq 0 ) {
        return
    }

    # Подключаемся к клиенту.
    Initialize-Client

    $runs = [math]::Ceiling( $total_count / $step )
    Write-Host ( 'Начинаем обработку. Потребуется итераций {0}.' -f $runs )
    For ( $i = 1; $i -le $runs; $i++ ) {
        $selected = Get-FileFirstContent $finished_list $step

        $hashes = @{}
        $selected | % { $id, $hash = ( $_.Split('.')[0] ).Split('_'); $hashes[$hash] = $id }

        Write-Host ( 'Итерация {0}/{1}, раздач {2}, опрашиваем клиент.' -f $i, $runs, $hashes.count )
        $torrents = Get-ClientTorrents $hashes.keys
        # Выбираем только раздачи подходящей категории.
        $torrents = $torrents | ? { $_.category -eq $uploader.delete_category }
        if ( !$torrents ) {
            Write-Host ( 'Нет раздач, которые требуется удалить. Пропускаем.' )
            Continue
        }

        foreach ( $torrent in $torrents ) {
            $torrent_id = $hashes[$torrent.hash]
            # Собираем имя и путь хранения архива раздачи.
            $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id

            $zip_google_path = $google_params.folders[0] + $disk_path + $torrent_id + '_' + $torrent.hash + '.7z'
            $zip_test = Test-PathTimer $zip_google_path
            # Если в облаке раздача есть, то её можно смело удалять из клиента
            if ( $zip_test.result ) {
                Write-Host ( '[cleaner] Пробуем удалить раздачу {0}, {1}' -f $torrent_id, $torrent.name )
                Remove-ClientTorrent $torrent_id $torrent.hash
            } else {
                Write-Host ( '[cleaner] Раздачи ещё нет в облаке {0}, {1}' -f $torrent_id, $torrent.name )
                Dismount-ClientTorrent $torrent_id $torrent.hash
            }
            Start-Sleep 1
        }
    }
    # end foreach

    Write-Host ( 'Обработано {0} раздач.' -f $total_count )
}

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

$ScriptName = (Get-Item $PSCommandPath).BaseName
$errors = @()
if ( !$used_modules.cleaner ) {
    $errors += 'Вы запустили {0}, хотя он не включён в настройках. Проверьте настройки $used_modules.' -f $ScriptName
}

if ( !$uploader.delete ) {
    $errors += '[cleaner] Опция удаления раздач выключена. Если вы хотите удалять обработанные раздачи, сперва включите.'
}
if ( !$uploader.delete_category ) {
    $errors += '[cleaner] Не указана категория раздач, которые следует удалять.'
}
if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Pause; Exit }

Start-Pause
Start-Stopping

if ( !$client_list ) {
    $client_list = @( $client )
}

foreach ( $cl in $client_list ) {
    Write-Host ''
    Write-Host ( '[cleaner] Подключаемся к торрент-клиенту "{0}", ищем раздачи, которые следует удалить из него.' -f $cl.name ) -ForegroundColor DarkCyan
    # Подключаемся к выбранному клиенту.
    $client = Select-Client $cl.name
    . (Connect-Client)

    # Ищем и удаляем раздачи.
    Clear-ClientDownloads
}

Start-Sleep 5
# Очистим папку загрузок, если закачка происходит с учётом ид раздачи.
if ( $collector.sub_folder ) {
    Clear-EmptyFolders $collector.collect
}
