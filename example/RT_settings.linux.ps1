# Параметры доступа к WebUI торрент-клиента.
$client = @{
    name     = 'myuniqname'              # Уникальное имя клиента, использовано для ханения временных файлов.
    type     = 'qbittorrent'             # Тип клиента [qbittorrent|transmission]
    url      = 'http://192.168.0.1:8090' # URL доступа к WebUI
    login    = 'admin'                   # Логин
    password = 'admin'                   # Пароль
}

# Параметры подключенных гугл дисков.
$google_params = @{
    # Пути к каталогам Google Drive (по одному на учётку Google).
    folders = @(
        '/data/shared'
    )
}

## Параметры связанные с ахривацией [backuper]
$backuper = @{
    # ссылка на архиватор 7z
    p7z = '7z'
    # [number] Колво ядер процессора, которые используются в архивировании
    cores = 1
    # Путь к каталогу хранения архивов и лимит занятого объёма
    zip_folder = '/data/backuper'
}
