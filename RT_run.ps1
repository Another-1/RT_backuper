# Задаем файл из которых будем читать список раздач, которые надо обновить сейчас
$hashes_file = "$PSScriptRoot/config/hashes.txt"

$runs = 1
while( $runs -le 9999 ) {
    $uselles_run = $true
    if ( Test-Path -path $hashes_file ) {
        # Читаем список хешей, которые следует обработать
        $hashes = Get-Content $hashes_file | Get-Unique
        # Очищаем файл
        Clear-Content -Path $hashes_file
    }

    if ( $hashes.count -gt 0 ) {
        Write-Host ( 'Найдено хешей для обработки: ' + $hashes.count )
        foreach ($hash in $hashes) {
            Write-Host ( $hash )
            .$PSScriptRoot/RT_backuper_New.ps1 $hash
        }
        $uselles_run = $false
    }
    else {
        .$PSScriptRoot/RT_backuper_New.ps1
    }
    if ( $uselles_run ) {
        Write-Output "Подождём часик и попробуем ещё раз. Счётчик цикла: $runs"
        Start-Sleep -Seconds (60 * 60)
    }
    $runs++
}
