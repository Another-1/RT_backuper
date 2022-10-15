# Поправить путь к вашему файлу, а точнее к папке config
$hashes_file = "D:\RT_backuper\config\hashes.txt"
If ( !(Test-Path $hashes_file) ) {
    New-Item -ItemType File -Path $hashes_file -Force > $null
}
if ( $args ) {
    $args[0] | Out-File $hashes_file -Append
}

# Пример запуска:
# powershell '%I' | Out-File 'D:\RT_backuper\config\hashes.txt' -Append
# powershell D:\add_hash.ps1 '%I'
