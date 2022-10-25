# Параметры доступа к WebUI торрент-клиента.
$client = @{
    name     = 'myuniqname'              # Имя клиента, используется для разделения временных файлов
    type     = 'qbittorrent'             # Тип клиента [qbittorrent|transmission]
    url      = 'http://192.168.0.1:8090' # URL доступа к WebUI
    login    = 'admin'                   # Логин
    password = 'admin'                   # Пароль
}

# учётные данные форума
$rutracker = @{
    login    = 'forum_login'
    password = 'forum_password'
}

# адрес, логин и пароль прокси-сервера
$proxy_address = 'http://45.8.144.130:3128'
$proxy_login = 'keepers'
$proxy_password = 'Sgssqb19Ijg'

# Параметры подключенных гугл дисков.
$google_params = @{
    # Пути к каталогам Google Drive (по одному на учётку Google).
    folders = @(
        'M:\Общие диски'
    )
    # Параметры ниже влияют на балансировку выгрузки в разные учётки гугла (если их >1) и на сортировку при паралельной выгрузке в >1 потока.
    # Теоретически не ограничено, однако смысла в >3 не вижу.
    # [number] Фактическое количество используемых аккаунтов (может быть больше колва дисков при использовании rclone).
    accounts_count = 1

    # Путь к кешу гугл диск и размер, превышение которого нежелательно.
    # Папка временных файлов клиента Google Drive (можно посмотреть и передвинуть в "Настройки" - Шестерёнка справа-сверху - "Локальная папка для хранения файлов из кеша").
    cache = 'D:\CacheFS'
    # Судя по документации гугла, размер кеша по умолчанию равен 20% от размера всего диска. Хз как это регулировать
    cache_size = 60 * [math]::Pow(1024, 3) # Гб
}

## Параметры связанные с ахривацией [backuper]
$backuper = @{
    # ссылка на архиватор 7z
    p7z = 'C:\Program Files\7-Zip\7z.exe'
    # [0/1] Скрывать ли вывод процесса архивации/проверки
    h7z = 0
    # [number] Колво ядер процессора, которые используются в архивировании
    cores = 1

    # [0/1] Если включено, то backuper НЕ БУДЕТ искать раздачи по всему клиенту. Будет использован только файл hashes.txt.
    hashes_only = 0
    # [number] Кол-во хешей, забираемых из файла за раз.
    hashes_step = 30

    # Актуально в случае когда backup и upload выполняется разными процессами.
    # Путь к каталогу хранения архивов и лимит занятого объёма
    zip_folder = 'D:\zip_backuper'
    zip_folder_size = 50 * [math]::Pow(1024, 3) # Гб

    # [number] Степень сжатия архива по умолчанию (0-без сжатия)
    compression = 1
    # Степень сжатия архива в зависимости от подраздела. Уже сжатый контент (видео, архивы) - сжимать смысла нет.
    # от 0 до 9, если не указано - то берётся из предыдущей настройки. 0 - без сжатия, 9 - максимальное сжатие
    sections_compression = @{
        110  = 0 # сериалы
        235  = 0 # сериалы
        266  = 0 # сериалы
        594  = 0
        704  = 0
        1105 = 0 # аниме
        1258 = 0
    }
}

## Параметры связанные с выгрузкой в гугл и последующей очисткой [uploader + cleaner]
$uploader = @{
    delete   = 0             # [0/1] Удалять ли раздачу из клиента, после архивирования.
    delete_category = 'temp' # Категория раздачи в клиенте, проверяемая при удалении раздач после архивирования.
}

## Параметры связанные с закачкой новых раздач [collector]
$collector = @{
    # каталог, в который скачивать раздачи
    collect      = 'D:\downloads'
    collect_size = 50 * [math]::Pow(1024, 3)  # Гб
    # [0/1] cоздавать ли подкаталоги по ID для раздачи при восстановлении из архивов. 1 - создавать, 0 - не надо
    sub_folder = 1
    # каталог временных файлов для скачивания .torrent
    tmp_folder = 'D:\zip_temp'
    # Категория, которая будет проверена при попытке удалить раздачу из клиента
    category = $uploader.delete_category
}


## Блок расписания. Работаем только в заданный промежуток времени            #
# Время начала период работы                                                 #
$start_time = [System.TimeOnly]'22:00'                                       #
                                                                             #
# Время окончания период работы                                              #
$stop_time  = [System.TimeOnly]'06:00'                                       #
                                                                             #
## Если не нужен, то удалите его полностью.                                  #
