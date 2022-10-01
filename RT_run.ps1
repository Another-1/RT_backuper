# Задаем файл из которых будем читать список раздач, которые надо обновить сейчас
$hashes_file = "$PSScriptRoot/stash/hashes.txt"


$runs = 0
while( $runs -le 9999 ) {
    if ( $args.count -gt 0) {
         if ( $args[0] -eq 'backuper' ) {
            .$PSScriptRoot/RT_backuper.ps1
         }
         if ( $args[0] -eq 'uploader' ) {
            .$PSScriptRoot/RT_uploader.ps1
         }
    }
    Write-Output ('Подождём часик и попробуем ещё раз. Счётчик цикла: {0}' -f ++$runs )
    Start-Sleep -Seconds (60 * 60)
}
