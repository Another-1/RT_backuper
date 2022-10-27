Param (
    [ValidateSet('backuper', 'uploader', 'cleaner')][string]$Process,
    [ValidateRange('Positive')][int]$Timer = 60,

    [string]$UsedClient = $null
)
# Зацикливаем файл. Если передано название файла, то вызываем его.
$run = @{
    num = 0
    timer = $Timer
    start = $null
    file = $null
    exec_time = 0
}
if ( $Process ) {
    $run.file = "$PSScriptRoot/RT_{0}.ps1" -f $Process
}

# Clear-Host
while( $true ) {
    $run.start = Get-Date

    if ( $run.file ) {
        Write-Output ( '[{0:t}] Params: [{1}], file: {2}' -f (Get-Date), ($args -Join ','), $run.file )
        if ( Test-Path $run.file ) {
            .$run.file -UsedClient $UsedClient
        }
    }

    $run.num++
    $run.exec_time = [math]::Round( ((Get-Date) - $run.start).TotalMinutes )
    $timer = if ( $run.exec_time -lt $run.timer ) { $run.timer - $run.exec_time } else { 5 }
    Write-Output ( '[{0:t}] Подождём {1} минут и попробуем ещё раз. Счётчик цикла: {2}' -f (Get-Date), $timer, $run.num )
    Start-Sleep -Seconds ($timer * 60)
}
