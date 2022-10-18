# Зацикливаем файл. Если передано название файла, то вызываем его.
# name_param timer
#   RT_{name} - название файла, который будет вызван
#   param     - параметр, который будет передан в вызываемый файл
#   timer     - переопределение паузы между итерациями цикла
$run = @{
    num = 0
    timer = 60
    start = $null
    file = $null
    exec_time = 0
}
if ( $args.count -gt 0 ) {
    if ( $args[1] ) {
        try { $run.timer = [int]$args[1] } catch {}
    }

    $proc, $param = $args[0].trim('-').Split('-')
    $run.file = "$PSScriptRoot/RT_{0}.ps1" -f $proc
}

while( $true ) {
    $run.start = Get-Date

    if ( $run.file ) {
        Write-Output ( '[{0}] Params: [{1}], file: {2}' -f (Get-Date -Format t), ($args -Join ','), $run.file )
        if ( Test-Path $run.file ) {
            if ( $param ) {
                .$run.file $param
            } else {
                .$run.file
            }
        }
    }

    $run.num++
    $run.exec_time = [math]::Round( ((Get-Date) - $run.start).TotalMinutes )
    $timer = if ( $run.exec_time -lt $run.timer ) { $run.timer - $run.exec_time } else { 5 }
    Write-Output ( '[{0}] Подождём {1} минут и попробуем ещё раз. Счётчик цикла: {2}' -f (Get-Date -Format t), $timer, $run.num )
    Start-Sleep -Seconds ($timer * 60)
}
