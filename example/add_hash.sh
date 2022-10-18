#!/bin/bash
# Поправить путь к вашему файлу, а точнее к папке config
# /config/qBittorrent/config/hashes.txt
echo $1 >> /pwsh/hashes.txt

# Пример запуска:
# /pwsh/add_hash.sh "%I"
# /config/qBittorrent/add_hash.sh "%I"
