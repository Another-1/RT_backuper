# Задаем файл из которых будем читать список раздач, которые надо обновить сейчас
$hashes_file = "$PSScriptRoot/stash/hashes.txt"

$runs = 0
while( $runs -le 9999 ) {
    if ( $args.count -gt 0) {
        Write-Output ( $args )
        $run_file = "$PSScriptRoot/RT_{0}.ps1" -f $args[0]
        Write-Output ( $run_file )
        if ( Test-Path $run_file) {
            .$run_file
        }
    }
    Write-Output ('Подождём часик и попробуем ещё раз. Счётчик цикла: {0}' -f ++$runs )
    Start-Sleep -Seconds (60 * 60)
}
