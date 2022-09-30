# ссылка на WebUI qBittorrent.
$client_url = 'http://192.168.0.232:8082'

# учётные данные для WebUI qBittorrent.
$webui_login = 'webui_login'
$webui_password = 'webui_password'

# тут указываем каталоги общих папок Google Drive (по одному на учётку Google).
$google_folders = @(
    'M:\Shared drives'
    'O:\Shared drives'
)
# Количество подключённых клиентов по одному пути
$google_folders_count = 1

# адрес, логин и пароль прокси-сервера
$proxy_address = 'http://45.8.144.130:3128'
$proxy_login = 'keepers'
$proxy_password = 'Sgssqb19Ijg'

# ссылка на архиватор 7z
$7z_path = 'c:\Program Files\7-Zip\7z.exe'

# тут указываем диск, на котором находится папка временных файлов клиента Google Drive (можно посмотреть и передвинуть в "Настройки" - Шестерёнка справа-сверху - "Локальная папка для хранения файлов из кеша").
# нужно для того, чтобы сделать паузу на закачивание при архивировании, если эта папка переполнится, и скинуть очередной архив будет некуда.
$drive_fs = 'K'

# тут нужно указать временный локальный диск, на котором будут создаваться архивы до того, как будут переложены в папку гуглодиска, чтобы оне не пытался начинать закачку по мере архивации. Возможно, это и не требуется. 
$tmp_drive = 'E'

# количество ядер процессора, задействованных для архивации
$cores = 4

# степень сжатия архив по умолчанию (если ниже на уровне подраздела не указано иное)
$default_compression = 1

# степень сжатия архивов в зависимости от подраздела (от 0 до 9, если не указано - то берётся из предыдущей настройки. 0 - без сжатия, 9 - максимальное сжатие)
$sections_compression = @{
    594  = 0
    704  = 0
    1258 = 0
}

## блок расписания работы скрипта. Если не нужен, то удалите его полностью.  #
# Время запуска при необходимости работы по расписанию                       #
$start_time = [System.TimeOnly]'21:00'                                       #
                                                                             #
# Время остановки при необходимости работы по расписанию                     #
$stop_time = [System.TimeOnly]'08:00'                                        #

## прочие настройки, не связанные с зеркалированием раздач.

# флаг удаления завешённых раздач. Если 1, то скачанные раздачи после архивации удаляются из клиента. Если 0, то нет.
$delete_processed = 0

# учётные данные форума
$rutracker_login = 'forum_login'
$rutracker_password = 'forum_password'

# осздавать ли подкаталоги по ID для раздачи при восстановлении из архивов. 1 - создавать, 0 - не надо
$torrent_folders = 0

# каталог временных файлов для скачивания .torrent
$temp_folder = 'C:\TEMP'

# каталог для распаковки добавляемых раздач при восстановлении
$store_path = 'E:\Хранимое\Прочее'

# максимальное количество сидов для подхвата
$max_seeders = 3

# категория для скачиваемых раздач. Если не указана, берётся с трекера
$default_category = 'Временное'
