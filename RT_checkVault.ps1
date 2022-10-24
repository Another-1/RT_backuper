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
Write-Host ( '- [folders] каталогов [{0}]' -f $google_params.folders.count )
Write-Host ( '- [accounts_count] фактических аккаунтов: [{0}]' -f $google_params.accounts_count )

$google_params.folders | % {
    Write-Host ( '- - "{0}" - внутри каталогов: {1} из 24х' -f $_, (Get-ChildItem $_ -Directory).count )
}

if ( $google_params.cache ) {
    Write-Host ( '- [cache] указана каталог кеша "{0}"' -f $google_params.cache )

    if ( $google_params.cache_size ) {
        $size = Get-BaseSize $google_params.cache_size
        $current_size = Get-BaseSize ( Get-FolderSize $google_params.cache )
        Write-Host ( '- [cache_size] лимит размера кеша: {0}, сейчас занято: {1}' -f $size, $current_size )
    } else {
        Write-Host ( '- [cache_size] лимит размера кеша не задан' )
    }
}

Write-Host ''
Write-Host ( 'Настройки бекапера [backuper]:' ) -ForegroundColor Yellow
Write-Host ( '- [zip_folder] каталог хранения архивов в процессе работы: "{0}"' -f $backuper.zip_folder )
if ( $backuper.zip_folder_size ) {
    $size = Get-BaseSize $backuper.zip_folder_size
    $current_size = Get-BaseSize ( Get-FolderSize $backuper.zip_folder )
    Write-Host ( '- [zip_folder_size] лимит размера каталога: {0}, сейчас занято: {1}' -f $size, $current_size )
} else {
    Write-Host ( '- [zip_folder_size] лимит размера каталога не задан' )
}
Write-Host ( '- [p7z] путь к 7z: "{0}"' -f $backuper.p7z )
Write-Host ( '- [h7z] опция скрывать вывод 7z: {0}' -f ( $temp = if ($backuper.h7z) {'включена'} else {'выключена'} ) )
Write-Host ( '- [cores] использование ядер при архивации: [{0}]' -f $backuper.cores )
Write-Host ( '- [compression] стандартная степень сжатия при архивации: [{0}]' -f $backuper.compression )

Write-Host ''
Write-Host ( 'Настройки аплоадера [uploader]:' ) -ForegroundColor Yellow
Write-Host ( '- [validate] валидация архива перед выгрузкой 7z: {0}' -f ( $temp = if ($uploader.validate) {'включена'} else {'выключена'} ) )
Write-Host ( '- [delete] удаление раздачи из клиента после выгрузки: {0}' -f ( $temp = if ($uploader.delete) {'включено'} else {'выключено'} ) )
if ( $uploader.delete ) {
    Write-Host ( '- [delete_category] удаляемая категория "{0}"' -f $uploader.delete_category )
}

Write-Host ''
Write-Host ( 'Настройки коллектора [collector]:' ) -ForegroundColor Yellow
Write-Host ( '- [category] категория присваемая новым раздачам "{0}"' -f $collector.category )
Write-Host ( '- [sub_folder] опция добавления раздачи в подкаталог по ИД {0}' -f ( $temp = if ($collector.sub_folder) {'включена'} else {'выключена'} ) )
Write-Host ( '- [collect] каталог, в который будут добавлено содержимое раздач "{0}"' -f $collector.collect )
if ( $collector.collect_size ) {
    $size = Get-BaseSize $collector.collect_size
    $current_size = Get-BaseSize ( Get-FolderSize $collector.collect )
    Write-Host ( '- [collect_size] лимит размера каталога: {0}, сейчас занято: {1}' -f $size, $current_size )
} else {
    Write-Host ( '- [collect_size] лимит размера каталога не задан' )
}
Write-Host ( '- [tmp_folder] каталог временного хранения торрент-файлов "{0}"' -f $collector.tmp_folder )
