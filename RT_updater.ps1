. "$PSScriptRoot\RT_functions.ps1"

if ( !(Confirm-Version) ) { Exit }
if ( !( Sync-Settings ) ) { Write-Host 'Проверьте наличие и заполненность файла настроек в каталоге скрипта';  Pause; Exit }

$os, $folder_sep = Get-OsParams

$arch_folders = Get-ChildItem $google_params.folders[0] -filter "$google_folder_prefix*" -Directory

$sleep_min = [math]::Round( 24 * 60 / ($arch_folders.count * 1.5 ) )

if ( $timer -ne $sleep_min ) {
  Write-Host ( 'Обнаружено дисков {0}, рекомендуемая пауза между запусками: {1} минут.' -f $arch_folders.count, $sleep_min )
}


# Собираем список гугл-дисков и проверяем наличие файла со списком архивов для каждого. Создаём если нет.
# Проверяем даты обновления файлов и размер. Если прошло 24ч или файл пуст -> пора обновлять.
# Выбираем первый диск по условиям выше и обновляем его.
$update_folder = $arch_folders | % { Watch-FileExist ($stash_folder.archived + '\' + $_.Name + '.txt') } |
  ? { $_.Size -eq 0 -Or $_.LastWriteTime -lt ( Get-Date ).AddHours(-24) } | Sort-Object -Property LastWriteTime | Select -First 1

if ( !$update_folder ) {
  Write-Host 'Нет списков для обновления. Выходим.'
  Exit
}

# Путь хранения архивов выбранного диска
$update_path = ( $arch_folders | ? { $_.BaseName -eq $update_folder.BaseName } ).FullName

Write-Host ( '[{0}] Начинаем обновление списка раздач диска.' -f $update_folder.BaseName )
$exec_time = (Measure-Command {
  $zip_list = Get-ChildItem $update_path -Filter '*.7z' -File
  if ( $zip_list.count ) {
    $zip_list | % { $_.BaseName } | Out-File $update_folder.FullName
  }
}).TotalSeconds

$text = '[{0}] Обновление списка раздач заняло {1} секунд. Найдено архивов: {2} шт.'
Write-Host ( $text -f $update_folder.BaseName, ([math]::Round( $exec_time, 2 )), $zip_list.count )
