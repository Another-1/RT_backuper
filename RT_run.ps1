# Зацикливаем файл. Если передано название файла, то вызываем его.
# name_param timer
#   RT_{name} - название файла, который будет вызван
#   param     - параметр, который будет передан в вызываемый файл
#   timer     - переопределение паузы между итерациями цикла
$runs = 0
while( $true ) {
    $timer = 60
    if ( $args.count -gt 0 ) {
        $proc, $param = $args[0].Split('_')
        $run_file = "$PSScriptRoot/RT_{0}.ps1" -f $proc
        Write-Output ( 'Params: [{0}], file: {1}' -f ($args -Join ','), $run_file )
        if ( Test-Path $run_file ) {
            .($run_file + $param).trim()
        }
        if ( $args[1] -ne $null ) {
            try { $timer = [int]$args[1] } catch {}
        }
    }
    Write-Output ( '{0} Подождём {1} минут и попробуем ещё раз. Счётчик цикла: {2}' -f (Get-Date -Format t), $timer, ++$runs )
    Start-Sleep -Seconds ($timer * 60)
}
