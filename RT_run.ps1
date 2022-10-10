# Зацикливаем файл. Если передано название файла, то вызываем его.
# name_param timer
#   RT_{name} - название файла, который будет вызван
#   param     - параметр, который будет передан в вызываемый файл
#   timer     - переопределение паузы между итерациями цикла
$run = @{
    num = 0
    timer = 60
    start = $null
    exec_time = 0
}
while( $true ) {
    $run.start = Get-Date
    if ( $args.count -gt 0 ) {
        if ( $args[1] -ne $null ) {
            try { $run.timer = [int]$args[1] } catch {}
        }

        $proc, $param = $args[0].trim('_').Split('_')
        $run_file = "$PSScriptRoot/RT_{0}.ps1" -f $proc
        Write-Output ( '[{0}] Params: [{1}], file: {2}' -f (Get-Date -Format t), ($args -Join ','), $run_file )
        if ( Test-Path $run_file ) {
            if ( $param ) {
                .$run_file $param
            } else {
                .$run_file
            }
        }
    }

    $run.exec_time = [math]::Round( ((Get-Date) - $run.start).TotalMinutes )
    $run.timer = if ( $run.exec_time -ge $run.timer ) { 1 } else { $run.timer - $run.exec_time }
    $run.num++
    Write-Output ( '[{0}] Подождём {1} минут и попробуем ещё раз. Счётчик цикла: {2}' -f (Get-Date -Format t), $run.timer, $run.num )
    Start-Sleep -Seconds ($run.timer * 60)
}
