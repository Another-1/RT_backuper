Param (
    [ValidateRange(0,3)][int]$Balance,

    [switch]$Verbose,
    [switch]$NoClient = $true
)

. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }

$ScriptName = (Get-Item $PSCommandPath).BaseName
$errors = @()
if ( !$used_modules.uploader ) {
    $errors += 'Вы запустили {0}, хотя он не включён в настройках. Проверьте настройки $used_modules.' -f $ScriptName
}
if ( !$used_modules.backuper ) {
    $errors += 'Вы запустили {0}, хотя backuper не включён в настройках. Проверьте настройки $used_modules.' -f $ScriptName
}
if ( !$used_modules.cleaner ) {
    $errors += 'Вы запустили {0}, хотя cleaner не включён в настройках. Проверьте настройки $used_modules.' -f $ScriptName
}
if ( $uploader.delete -and !$used_modules.cleaner ) {
    $errors += 'Включено удаление раздач после архивирования, то не включён cleaner. Или включите его или используйте Backuper_Full.'
}
if ( $errors ) { Write-Host ''; $errors | Write-Host -ForegroundColor Yellow; Pause; Exit }

Start-Pause
Start-Stopping

Write-Host '[uploader] Начинаем процесс выгрузки архивов в гугл.'

# Если используемых акков >1 и передан параметр с номером, то используем балансировку.
if ( $Balance -and $google_params.accounts_count -gt 1 ) {
    if ( $Balance -gt $google_params.uploaders_count ) {
        Write-Host ( '[balance] Неверный номер сервиса "{0}". Акканутов подключено {1}. Прерываем.' -f $Balance, $google_params.uploaders_count ) -ForegroundColor Red
        Exit
    }
    Write-Host ( '[balance] Включена многопоточная выгрузка. Номер сервиса: {0}' -f $Balance ) -ForegroundColor Yellow
}

# Ищем список архивов, которые нужно перенести
$zip_list = Get-ChildItem $def_paths.finished -Filter '*.7z' | Sort-Object $OS.sizeField

$proc_cnt = 0
$proc_size = 0
$sum_cnt = $zip_list.count
$sum_size = ( $zip_list | Measure-Object $OS.sizeField -Sum ).Sum
Write-Host ( '[uploader] Найдено архивов: {0} ({1}), требующих переноса на гугл-диск.' -f $sum_cnt, (Get-BaseSize $sum_size) ) -ForegroundColor DarkCyan
if ( !$sum_cnt ) { Exit }

Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 10)


# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
Show-StoredUploads $uploads_all

# Перебираем архивы.
Write-Host ( '[uploader][{0:t}] Начинаем перебирать раздачи.' -f (Get-Date) )
foreach ( $zip in $zip_list ) {
    # Ид и прочие параметры раздачи.
    $torrent_id, $torrent_hash = ( $zip.Name.Split('.')[0] ).Split('_')
    $zip_size = $zip.($OS.sizeField)

    # Собираем имя и путь хранения архива раздачи.
    $disk_id, $disk_name, $disk_path = Get-DiskParams $torrent_id

    # Вычисляем выгружаемый аккаунт и номер процесса выгрузки.
    $order = Get-GoogleNum $disk_id -Accounts $google_params.accounts_count -Uploaders $google_params.uploaders_count
    if ( $Balance -And $Balance -ne $order.upload ) {
        Write-Host ( '[skip] {0} для другого процесса [{1}].' -f $torrent_id, $order.upload ) -ForegroundColor Yellow
        Continue
    }

    # Если подключён один диск - указатель =0, если дисков > 1, то указатель =(выбранный акк-1)
    $folder_pointer = 0
    if ( $google_params.folders.count -gt 1 ) {
        $folder_pointer = $order.account - 1
    }
    $google_path = $google_params.folders[$folder_pointer]
    $google_name = ( '{0}({1})' -f $google_path, $order.account )

    $zip_path_finished = $def_paths.finished + $OS.fsep + $zip.Name
    $zip_google_path   = $google_path + $disk_path + $zip.Name

    Write-Host ''
    Write-Host ( '[torrent] Обрабатываем: id={0} ({4}), disk=[{1}], path={2} {3}' -f $torrent_id, $disk_id, $google_name, $disk_name, (Get-BaseSize $zip_size) ) -ForegroundColor Green

    try {
        if ( $uploader.validate ) {
            Write-Host '[check] Начинаем проверку целостности архива перед отправкой в гугл.'
            $start_measure = Get-Date

            Test-ZipIntegrity $zip_path_finished
            if ( $LastExitCode -ne 0 ) {
                throw ( '[check] Архив не прошёл проверку, код ошибки: {0}. Удаляем файл.' -f $LastExitCode )
            }

            $time_valid = [math]::Round( ((Get-Date) - $start_measure).TotalSeconds, 1 )
            Write-Host ( '[check] Проверка завершена за {0}.' -f (Get-BaseSize $time_valid -SI time) )
        }

        # Перед переносом проверяем доступный трафик.
        Compare-StoredUploads $google_name $uploads_all

        # Проверка переполнения каталога с кешем гугла.
        if ( $google_params.cache_size ) {
            Compare-MaxSize $google_params.cache $google_params.cache_size
        }

        $zip_test = Test-CloudPath $zip_google_path
        if ( $zip_test.result ) {
            throw '[skip] Такой архив уже существует на гугл-диске, удаляем файл и пропускаем раздачу.'
        }
        try {
            Write-Host 'Перемещаем архив на гугл-диск...'
            New-Item -ItemType Directory -Path ($google_path + $disk_path) -Force > $null

            $move_sec = [math]::Round( (Measure-Command {
                Move-Item -Path $zip_path_finished -Destination ( $zip_google_path ) -Force -ErrorAction Stop
            }).TotalSeconds, 1 )
            if ( !$move_sec ) {$move_sec = 0.1}

            $speed_move = (Get-BaseSize ($zip_size / $move_sec) -SI speed_2)
            Write-Host ( '[uploader] Готово! Завершено за {0}, средняя скорость {1}' -f (Get-BaseSize $move_sec -SI time) , $speed_move )

            # После успешного переноса архива записываем затраченный трафик
            Get-TodayTraffic $uploads_all $zip_size $google_name > $null
        }
        catch {
            Write-Host '[uploader] Не удалось отправить файл на гугл-диск'
            Write-Host ( '{0} => {1}' -f $zip_path_finished, $zip_google_path )
            Pause
        }
    } catch {
        if ( Test-Path $zip_path_finished ) { Remove-Item $zip_path_finished }
        Write-Host $Error[0] -ForegroundColor Red
    }

    $proc_size += $zip_size
    $text = '[uploader][{4:t}] Обработано раздач {0} ({1}) из {2} ({3})'
    Write-Host ( $text -f ++$proc_cnt, (Get-BaseSize $proc_size), $sum_cnt, (Get-BaseSize $sum_size), (Get-Date) ) -ForegroundColor DarkCyan

    Start-Pause
    Start-Stopping

    Sync-ArchList -Name $disk_name
}
# end foreach
