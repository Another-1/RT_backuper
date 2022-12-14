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
        'M:\Общие диски'
    )

    # Путь к кешу гугл диска и размер, превышение которого нежелательно.
    cache = 'D:\CacheFS'
    # Следует указать величину равную 20% от размера всего диска, на который был кеш.
    cache_size = 60 * [math]::Pow(1024, 3) # Гб
}

## Параметры связанные с архивацией [backuper]
$backuper = @{
    # ссылка на архиватор 7z
    p7z = 'C:\Program Files\7-Zip\7z.exe'
    # [number] Колво ядер процессора, которые используются в архивировании
    cores = 1
    # Путь к каталогу хранения архивов
    zip_folder = 'D:\zip_backuper'
}
