Write-Host 'Добро пожаловать в инструментарий истинного архивариуса' -ForegroundColor Blue
Write-Host 'Осматриваемся, всё ли в порядке'

Write-Host 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
else { Write-Host 'Версия Powershell мне нравится!' -ForegroundColor Green }

Write-Host 'Проверяем наличие файла настроек...'
$github_uri = 'https://raw.githubusercontent.com/Another-1/RT_backuper/main/'
$settings_file = 'RT_settings.ps1'
$backuper_file = 'RT_backuper_New.ps1'
$collector_file = 'RT_collector.ps1'

if ( $PSVersionTable.OS.ToLower().contains('windows')) { $separator = '\' } else { $separator = '/' }
if ( -not ( Test-Path ( $PSScriptRoot + $separator + 'RT_settings.ps1') ) ) {
    Write-Host ( 'Файл с настройками ' + $PSScriptRoot + $separator + $settings_file + ' не найден!' ) -ForegroundColor Red
    if ( ( ( Read-Host -Prompt 'Хотите загрузить заготовку с Github и подрежактировать под себя? Y/N' ).ToString() ).ToLower() -eq 'y' ) {
        Write-Host 'Загружаем заготовку файла настроек'
        try {
            Invoke-WebRequest -Uri ( $github_uri + $settings_file ) -OutFile ( $PSScriptRoot + $separator + $settings_file )
            Write-Host 'Файл успешно скачан. Откройте в тестовом редакторе файл RT_settings рядом со мной, настройте под себя и запустите меня заново.'
        }
        catch {
            Write-Host "Не получилось скачать. Скачайте самостоятельно файл $settings_uri, положите рядом со мной, настройте под себя и запустите меня заново."
        }
        Write-Output 'А пока я с вами прощаюсь, до новых встреч!'
        Pause
    }
}
else { Write-Host 'Файл с настройками нашёлся, отлично! Загружаем.' -ForegroundColor Green }
. ( $PSScriptRoot + $separator + $settings_file )

while ( $true ) {
    $choice = ( ( Read-Host -Prompt 'Хотите, я на всякий случай обновлю все скрипты?  Y/N' ).ToString() ).ToLower() 
    if ($choice -eq 'y') {
        Write-Host 'Правильное решение!'
        Write-Host 'Обновляяю скрипт архивации..'
        try { Invoke-WebRequest -Uri ( $github_uri + $backuper_file ) -OutFile ( $PSScriptRoot + $separator + $backuper_file ) }
        catch { Write-Host 'Почему-то не получилось скачать свижий скрипт архивации. Извините :(' -ForegroundColor Red }
        Write-Host 'Обновляяю скрипт подхвата..'
        try { Invoke-WebRequest -Uri ( $github_uri + $collector_file ) -OutFile ( $PSScriptRoot + $separator + $collector_file ) }
        catch { Write-Host 'Почему-то не получилось скачать свижий скрипт подхвата. Извините :(' -ForegroundColor Red }
        exit
    }
    elseif ( $choice -eq 'n' ) {
        Write-Host 'Как хотите..'
        break
    }
    Write-Host 'Я ничего не понял, повторите.'
}
while ( $true ) {
    Write-Host ''
    Write-Host 'Чем займёмся?'
    Write-Host '0. Ничем, передумал'
    Write-Host '1. Зеркалированием'
    Write-Host '2. Подхватом'
    $choice = Read-Host 'Вам решать'
    switch ($choice) {
        0 { 
            exit
        }
        1 {
            . ( $PSScriptRoot + $separator + $backuper_file )
            exit 
        }
        2 {
            . ( $PSScriptRoot + $separator + $collector_file ) 
            exit
        }
        Default {}
    }
}