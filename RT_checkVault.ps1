. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Pause; Exit }


Write-Host ''
Write-Host ( 'Система: {0}' -f $OS.name ) -ForegroundColor Yellow
if ( $start_time -and $stop_time ) {
    Write-Host ( '[start_time,stop_time] Расписание работы, период ({0} - {1})' -f $start_time, $stop_time )
}


Write-Host ''
Write-Host ( 'Настройки для клиента "{0}" [{1}].' -f $client.name, $client.type ) -ForegroundColor Yellow
Write-Host ( '- url: {0}; login: "{1}".' -f $client.url, $client.login )

Initialize-Client
Get-ClientVerion

Write-Host ''
Write-Host ( '[rutracker] Логин для форума: {0}' -f $rutracker.login ) -ForegroundColor Yellow
# Добавить вывод авторизации на форуме или типа того.

Write-Host ( 'Используется прокси: {0} {1}:***' -f $proxy_address, $proxy_login )

Write-Host ''
Write-Host ( 'Настройки подключённых гугл-дисков:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} каталогов [{1}]' -f '[folders]', $google_params.folders.count )
Write-Host ( '- {0,-18} фактических аккаунтов: [{1}]' -f '[accounts_count]', $google_params.accounts_count )

$google_params.folders | % {
    Write-Host ( '- - "{0}" - внутри каталогов: {1} из 24х' -f $_, (Get-ChildItem $_ -Directory).count )
}

if ( $google_params.cache ) {
    Write-Host ( '- {0,-18} указана каталог кеша "{1}"' -f '[cache]', $google_params.cache )

    if ( $google_params.cache_size ) {
        $size = Get-BaseSize $google_params.cache_size
        $current_size = Get-BaseSize ( Get-FolderSize $google_params.cache )
        Write-Host ( '- {0,-18} лимит размера кеша: {1}, сейчас занято: {2}' -f '[cache_size]', $size, $current_size )
    } else {
        Write-Host ( '- {0,-18} лимит размера кеша не задан' -f '[cache_size]')
    }
}

Write-Host ''
Write-Host ( 'Настройки бекапера [backuper]:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} каталог хранения архивов в процессе работы: "{1}"' -f '[zip_folder]', $backuper.zip_folder )
if ( $backuper.zip_folder_size ) {
    $size = Get-BaseSize $backuper.zip_folder_size
    $current_size = Get-BaseSize ( Get-FolderSize $backuper.zip_folder )
    Write-Host ( '- {0,-18} лимит размера каталога: {1}, сейчас занято: {2}' -f '[zip_folder_size]', $size, $current_size )
} else {
    Write-Host ( '- {0,-18} лимит размера каталога не задан' -f '[zip_folder_size]' )
}
Write-Host ( '- {0,-18} путь к 7z: "{1}"' -f '[p7z]', $backuper.p7z )
Write-Host ( '- {0,-18} опция скрывать вывод 7z: {1}' -f '[h7z]', ( $temp = if ($backuper.h7z) {'включена'} else {'выключена'} ) )
Write-Host ( '- {0,-18} использование ядер при архивации: [{1}]' -f '[cores]', $backuper.cores )
Write-Host ( '- {0,-18} стандартная степень сжатия при архивации: [{1}]' -f '[compression]', $backuper.compression )

Write-Host ''
Write-Host ( 'Настройки аплоадера [uploader]:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} валидация архива перед выгрузкой 7z: {1}' -f '[validate]', ( $temp = if ($uploader.validate) {'включена'} else {'выключена'} ) )
Write-Host ( '- {0,-18} удаление раздачи из клиента после выгрузки: {1}' -f '[delete]', ( $temp = if ($uploader.delete) {'включено'} else {'выключено'} ) )
if ( $uploader.delete ) {
    Write-Host ( '- {0,-18} удаляемая категория "{1}"' -f '[delete_category]', $uploader.delete_category )
}

Write-Host ''
Write-Host ( 'Настройки коллектора [collector]:' ) -ForegroundColor Yellow
Write-Host ( '- {0,-18} категория присваемая новым раздачам "{1}"' -f '[category]', $collector.category )
Write-Host ( '- {0,-18} опция добавления раздачи в подкаталог по ИД {1}' -f '[sub_folder]', ( $temp = if ($collector.sub_folder) {'включена'} else {'выключена'} ) )
Write-Host ( '- {0,-18} каталог, в который будут добавлено содержимое раздач "{1}"' -f '[collect]', $collector.collect )
if ( $collector.collect_size ) {
    $size = Get-BaseSize $collector.collect_size
    $current_size = Get-BaseSize ( Get-FolderSize $collector.collect )
    Write-Host ( '- {0,-18} лимит размера каталога: {1}, сейчас занято: {2}' -f '[collect_size]', $size, $current_size )
} else {
    Write-Host ( '- {0,-18} лимит размера каталога не задан' -f '[collect_size]' )
}
Write-Host ( '- {0,-18} каталог временного хранения торрент-файлов "{1}"' -f '[tmp_folder]', $collector.tmp_folder )
