Param (
    [switch]$Full,
    [switch]$Skip,
    [switch]$NoClient = $true,
    [switch]$Verbose,

    [ArgumentCompleter({ param($cmd, $param, $word) [array](Get-Content "$PSScriptRoot/clients.txt") -like "$word*" })]
    [string]
    $UsedClient
)

Clear-Host
. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) {
    Write-Host 'Не обнаружен файл конфигурации, создать шаблон? [y/n]: ' -ForegroundColor Green -NoNewLine
    $ch_config = ( Read-Host ).ToString().ToLower()
    if ( $ch_config -in 'y','д' ) {
        $settings_example = "$PSScriptRoot/example/RT_settings.{0}.ps1" -f $OS.name
        $settings_local   = "$PSScriptRoot/config/RT_settings.ps1"
        $settings_example
        $settings_local
        if ( Test-Path $settings_example ) {
            Copy-Item $settings_example -Destination $settings_local -Force
            Write-Host 'Файл конфигурации создан, откройте его и отредактируйте под свои нужды.'
        } else {
            
        }
    }
    Exit
}

function Hide-Password ( [string]$psw ) {
    return $psw[0] + '****' + $psw[-1]
}

Write-Host ''
Write-Host ( 'Система: {0}, версия скриптов: v{1}' -f $OS.name, $RT_version ) -ForegroundColor Yellow
if ( $start_time -and $stop_time ) {
    Write-Host ( '[start_time,stop_time] Расписание работы, период ({0} - {1})' -f $start_time, $stop_time )
}


Write-Host ''
Write-Host ( 'Настройки подключённых гугл-дисков:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} каталогов: [{1}]' -f '[folders]', $google_params.folders.count )
Write-Host ( '- {0,-18} фактических аккаунтов: [{1}]' -f '[accounts_count]', $google_params.accounts_count )

$google_params.folders | % {
    $subfolder_count = (Get-ChildItem $_ -Directory -Filter "$google_folder_prefix*").count
    Write-Host ( '- - "{0}" - внутри каталогов: {1} из 24х' -f $_, $subfolder_count )
}

if ( $google_params.cache ) {
    Write-Host ( '- {0,-18} каталог кеша [{1}]' -f '[cache]', $google_params.cache )

    if ( $google_params.cache_size ) {
        $size = Get-BaseSize $google_params.cache_size
        $current_size = Get-BaseSize ( Get-FolderSize $google_params.cache )
        Write-Host ( '- {0,-18} лимит размера кеша: {1}, сейчас занято: {2}' -f '[cache_size]', $size, $current_size )
    } else {
        Write-Host ( '- {0,-18} лимит размера кеша не задан' -f '[cache_size]')
    }
}
if ( $google_params.decay_hours ) {
    Write-Host ( '- {0,-18} время устаревания локального списка архивов [{1} ч]' -f '[decay_hours]', $google_params.decay_hours )
}


Write-Host ''
# Ищем данные о прошлых выгрузках в гугл.
$uploads_all = Get-StoredUploads
Show-StoredUploads $uploads_all


Write-Host ( 'Настройки бекапера [backuper]:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} каталог хранения архивов в процессе работы: [{1}]' -f '[zip_folder]', $backuper.zip_folder )
if ( $backuper.zip_folder_size ) {
    $size = Get-BaseSize $backuper.zip_folder_size
    $current_size = Get-BaseSize ( Get-FolderSize $backuper.zip_folder )
    Write-Host ( '- {0,-18} лимит размера каталога: {1}, сейчас занято: {2}' -f '[zip_folder_size]', $size, $current_size )
} else {
    Write-Host ( '- {0,-18} лимит размера каталога не задан' -f '[zip_folder_size]' )
}
Write-Host ( '- {0,-18} путь к 7z: [{1}]' -f '[p7z]', $backuper.p7z )
Write-Host ( '- {0,-18} опция скрывать вывод 7z: {1}' -f '[h7z]', ( $temp = if ($backuper.h7z) {'включена'} else {'выключена'} ) )
Write-Host ( '- {0,-18} использование ядер при архивации: [{1}]' -f '[cores]', $backuper.cores )
Write-Host ( '- {0,-18} стандартная степень сжатия при архивации: [{1}]' -f '[compression]', (Get-Compression -Params $backuper) )


Write-Host ''
Write-Host ( 'Настройки аплоадера [uploader]:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} валидация архива 7z перед выгрузкой : {1}' -f '[validate]', ( $temp = if ($uploader.validate) {'включена'} else {'выключена'} ) )
Write-Host ( '- {0,-18} удаление раздачи из клиента после выгрузки: {1}' -f '[delete]', ( $temp = if ($uploader.delete) {'включено'} else {'выключено'} ) )
if ( $uploader.delete ) {
    Write-Host ( '- {0,-18} удаляемая категория [{1}]' -f '[delete_category]', $uploader.delete_category )
}


Write-Host ''
Write-Host ( 'Настройки коллектора [collector]:' ) -ForegroundColor Yellow
if ( !$collector ) {
    Write-Host '- отсутствуют' -ForegroundColor Yellow
} else {
    Write-Host ( '- {0,-18} каталог, в который будут добавлено содержимое раздач [{1}]' -f '[collect]', $collector.collect )
    Write-Host ( '- {0,-18} опция добавления раздачи в подкаталог по ИД: {1}' -f '[sub_folder]', ( $temp = if ($collector.sub_folder) {'включена'} else {'выключена'} ) )
    Write-Host ( '- {0,-18} категория для добавленных раздач [{1}]' -f '[category]', $collector.category )
    if ( $collector.collect_size ) {
        $size = Get-BaseSize $collector.collect_size
        $current_size = Get-BaseSize ( Get-FolderSize $collector.collect )
        Write-Host ( '- {0,-18} лимит размера каталога: {1}, сейчас занято: {2}' -f '[collect_size]', $size, $current_size )
    } else {
        Write-Host ( '- {0,-18} лимит размера каталога не задан' -f '[collect_size]' )
    }
}

Write-Host ''
Write-Host ( 'Настройки подключения к форуму:' ) -ForegroundColor Yellow
if ( !$forum ) {
    Write-Host '- отсутствуют' -ForegroundColor Yellow
} else {
    Write-Host ( '- {0, -18} логин  {1}' -f '[login]', $forum.login )
    Write-Host ( '- {0, -18} пароль {1}' -f '[password]', (Hide-Password $forum.password) )
    Write-Host ( '- {0, -18} использование прокси для работы с форумом: {1}' -f '[proxy]', ( $temp = if ($forum.proxy) {'включено'} else {'выключено'} ) )
    if ( $forum.proxy ) {
        Write-Host ( '- {0, -18} {1}' -f '[proxy_url]', $forum.proxy_address )
        Write-Host ( '- {0, -18} {1}' -f '[proxy_login]', $forum.proxy_login )
        Write-Host ( '- {0, -18} {1}' -f '[proxy_password]', (Hide-Password $forum.proxy_password) )
    }
}


if ( !$Full -and !$Skip ) {
    Write-Host 'Принудительно обновить все списки существующих архивов? [y/n]: ' -ForegroundColor Green -NoNewLine
    $ch_refresh = ( Read-Host ).ToString().ToLower()
}
if ( !$Skip ) {
    $done_list, $done_hashes = Get-Archives -Force:($Full -or $ch_refresh -in 'y','д')
}

if ( !$client_list ) {
    $client_list = @( $client )
}
if ( $UsedClient ) {
    $client_list = @( $client_list | ? { $_.name -eq $UsedClient } )
}

if ( $client_list.count -gt 1 ) {
    Write-Host ''
    Write-Host ( 'Количество подключённых торрент-клиентов: {0}' -f $client_list.count ) -ForegroundColor Yellow
}
foreach ( $cl in $client_list ) {
    Write-Host ''
    # Подключаемся к выбранному клиенту.
    $client = Select-Client $cl.name
    . (Connect-Client)

    Write-Host ( 'Настройки для клиента "{0}" [{1}]' -f $client.name, $client.type ) -ForegroundColor Yellow
    Write-Host ( '- url: {0}; login: "{1}"; password: "{2}"' -f $client.url, $client.login, (Hide-Password $client.password) )
    Write-Host ( '- опция [hashes_only] для работы только с докачанными раздачами: {0}' -f ( $temp = if ($client.hashes_only) {'включена'} else {'выключена'} ) )

    Initialize-Client
    Get-ClientVersion

    if ( !$Full -and !$Skip ) {
        Write-Host 'Посчитать раздачи в клиенте? [y/n]: ' -ForegroundColor Green -NoNewLine
        $ch_client = ( Read-Host ).ToString().ToLower()
    }
    if ( $Full -or $ch_client -in 'y','д' ) {
        $torrents_list = Get-ClientTorrents
        $torrents_size = ( $torrents_list | Measure-Object size -Sum ).Sum
        Write-Host ( '[client] Завершённых раздач в клиенте: {0} ({1})' -f $torrents_list.count, (Get-BaseSize $torrents_size) ) -ForegroundColor DarkCyan

        if ( $done_hashes ) {
            $torrents_left = $torrents_list | ? { !$done_hashes[ $_.hash ] }
            $torrents_size = ( $torrents_left | Measure-Object size -Sum ).Sum
            Write-Host ( '[client] Раздач, которые нужно залить: {0} ({1})' -f $torrents_left.count, (Get-BaseSize $torrents_size) ) -ForegroundColor DarkCyan
        }
    }
}

Write-Host ''
$stash_size = Get-BaseSize ( Get-FolderSize $stash_folder.default )
Write-Host ( 'Каталог временных файлов [{1}], текущий размер: {2}' -f '[stash]', $stash_folder.default, $stash_size ) -ForegroundColor Yellow
