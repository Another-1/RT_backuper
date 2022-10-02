# Задаем файл из которых будем читать список раздач, которые надо обновить сейчас
$hashes_file = "$PSScriptRoot/stash/hashes.txt"

$runs = 0
while( $true ) {
    $timer = 60
    if ( $args.count -gt 0) {
        Write-Output ( 'Params: {0}' -f $args -Join ',' )
        $proc, $param = $args[0].Split('_')
        $run_file = "$PSScriptRoot/RT_{0}.ps1" -f $proc
        Write-Output ( $run_file )
        if ( Test-Path $run_file ) {
            .$run_file $param
        }
        if ( $args[1] -ne $null ) {
            try { $timer = [int]$args[1] } catch {}
        }
    }
    Write-Output ('{0} Подождём {1} минут и попробуем ещё раз. Счётчик цикла: {2}' -f (Get-Date -Format t), $timer, ++$runs )
    Start-Sleep -Seconds ($timer* 60)
}
