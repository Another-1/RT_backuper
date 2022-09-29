Clear-Host
Write-Host 'Добро пожаловать в инструментарий истинного архивариуса' -ForegroundColor Blue
Write-Host 'Осматриваемся, всё ли в порядке'

Write-Host 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
else { Write-Host 'Версия Powershell мне нравится!' -ForegroundColor Green }


if ( $PSVersionTable.OS.ToLower().contains('windows')) { $os = 'windows'; $separator = '\' } else { $os = 'linux'; $separator = '/' }

# Путь к гитхабу
$github_uri = 'https://raw.githubusercontent.com/Another-1/RT_backuper/main/'

# Файл настроек лежит в примерах
$settings_local_path = @( $PSScriptRoot, 'config', 'RT_settings.ps1' ) -join $separator
$settings_global_path = $github_uri + "example/RT_settings.$os.ps1"

# Остальные важные файлы
$functions_file  = 'RT_functions.ps1'
$wrapper_file    = 'RT_wrapper.ps1'
$backuper_file   = 'RT_backuper_New.ps1'
$collector_file  = 'RT_collector.ps1'
$restorator_file = 'RT_restorator.ps1'

Write-Host 'Проверяем наличие файла настроек...'
if ( -not ( Test-Path $settings_local_path ) ) {
    New-Item -Path ($PSScriptRoot + $separator + 'config') -ItemType Directory -Force
    Write-Host ( "Файл с настройками $settings_local_path не найден!" ) -ForegroundColor Red
    $choice = ( ( Read-Host -Prompt 'Хотите загрузить заготовку с Github и подредактировать под себя? Y/N' ).ToString() ).ToLower()
    if ( $choice -eq 'y' -or $choice -eq '' ) {
        Write-Host "Загружаем заготовку файла настроек ($os)"
        try {
            Invoke-WebRequest -Uri ( $settings_global_path ) -OutFile ( $settings_local_path )
            Write-Host 'Файл успешно скачан.'
            Write-Host 'Откройте в тестовом редакторе файл config/RT_settings рядом со мной, настройте под себя и запустите меня заново.'
        }
        catch {
            Write-Host "Не получилось скачать. Скачайте самостоятельно файл $settings_global_path, положите рядом со мной в папку /config, настройте под себя и запустите меня заново."
        }
        Write-Output 'А пока я с вами прощаюсь, до новых встреч!'
        Pause
        Exit
    }
    else {
        Write-Host 'Извините, но нет настроек - нет работы. До свидания.' -ForegroundColor Red
        Pause
        Exit
    }
}
else { Write-Host 'Файл с настройками нашёлся, отлично! Загружаем.' -ForegroundColor Green }

. ( $settings_local_path )

$required_files = @( $functions_file, $wrapper_file, $backuper_file, $collector_file, $restorator_file )
while ( $true ) {
    if ( $required_files | ForEach-Object { if ( -not (Test-Path ( $PSScriptRoot + $separator + $_) ) ) { return $true} } ) {
        $required = $true
        Write-Host ''
        Write-Host 'У вас нет некоторых нужных мне скриптов! Я без них никак.'
        $choice = ( ( Read-Host -Prompt 'Давайте я скачаю все скрипты? Y/N' ).ToString() ).ToLower()
    }
    else {
        $choice = ( ( Read-Host -Prompt 'Хотите, я на всякий случай обновлю все скрипты? Y/N' ).ToString() ).ToLower()
    }
    if ($choice -eq 'y' -or $choice -eq '') {
        Write-Host 'Правильное решение!'
        Write-Host 'Начну с себя o_O'
        $was_hash = Get-FileHash -Path ( $PSCommandPath )
        try {
            Invoke-WebRequest -Uri ( $github_uri + $wrapper_file ) -OutFile ( $PSCommandPath )
            $now_hash = Get-FileHash -Path ( $PSCommandPath )
            if ( $was_hash.hash -ne $now_hash.hash ) {
                Write-Host 'Ого, я обновился! Чтобы вы пользовались мной новым, я сейчас закроюсь. Перезапустите меня заново.'
                Pause
                Exit
            }

        }
        catch { Write-Host 'Почему-то не получилось скачать свежий вариант самого себя. Извините :(' -ForegroundColor Red }
        Write-Host 'Обновляю общие функции..'
        try { Invoke-WebRequest -Uri ( $github_uri + $functions_file ) -OutFile ( $PSScriptRoot + $separator + $functions_file ) }
        catch { Write-Host 'Почему-то не получилось скачать общие функции. Извините :(' -ForegroundColor Red }
        Write-Host 'Обновляю скрипт архивации..'
        try { Invoke-WebRequest -Uri ( $github_uri + $backuper_file ) -OutFile ( $PSScriptRoot + $separator + $backuper_file ) }
        catch { Write-Host 'Почему-то не получилось скачать свежий скрипт архивации. Извините :(' -ForegroundColor Red }
        Write-Host 'Обновляю скрипт подхвата..'
        try { Invoke-WebRequest -Uri ( $github_uri + $collector_file ) -OutFile ( $PSScriptRoot + $separator + $collector_file ) }
        catch { Write-Host 'Почему-то не получилось скачать свежий скрипт подхвата. Извините :(' -ForegroundColor Red }
        Write-Host 'Обновляю скрипт восстановления..'
        try { Invoke-WebRequest -Uri ( $github_uri + $restorator_file ) -OutFile ( $PSScriptRoot + $separator + $restorator_file ) }
        catch { Write-Host 'Почему-то не получилось скачать свежий скрипт восстановления. Извините :(' -ForegroundColor Red }
        break
    }
    elseif ( $choice -eq 'n' ) {
        Write-Host 'Как хотите..'
        if ( $required -eq $true ) { exit }
        break
    }
    Write-Host 'Я ничего не понял, повторите.'
}

while ( $true ) {
    Write-Host ''
    Write-Host 'Чем займёмся?'
    Write-Host '0. Ничем, я передумал'
    Write-Host '1. Зеркалированием'
    Write-Host '2. Подхватом'
    Write-Host '3. Восстановлением из архивов'
    $choice =  Read-Host 'Вам решать'
    Write-Host ''
    switch ($choice) {
        0 {
            exit
        }
        $nul {
            exit
        }
        '' {
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
        3 {
            . ( $PSScriptRoot + $separator + $restorator_file )
            exit
        }
        Default {
            Write-host ''
            Write-host 'Я ничего не понял, повторите.'
        }
    }
}
