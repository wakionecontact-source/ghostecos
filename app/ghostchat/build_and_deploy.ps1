# Билдит release APK, переименовывает в ghost_v{version}.apk,
# заливает на сервер как ghost.apk + ghost_v{version}.apk (для версионирования).
#
# Использование: pwsh ./build_and_deploy.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# 1. Версия из pubspec.yaml
$pubspec = Get-Content pubspec.yaml -Raw
$verMatch = [regex]::Match($pubspec, 'version:\s*([\d\.]+)\+\d+')
if (-not $verMatch.Success) { throw "Не нашёл version в pubspec.yaml" }
$ver = $verMatch.Groups[1].Value
Write-Host ">> Версия: $ver"

# 2. Сборка
Write-Host ">> flutter build apk --release"
flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw "Сборка упала" }

# 3. Переименование
$src = "build/app/outputs/flutter-apk/app-release.apk"
$verName = "ghost_v$ver.apk"
$dstLocal = "build/app/outputs/flutter-apk/$verName"
Copy-Item $src $dstLocal -Force
Write-Host ">> Локально: $dstLocal"

# 4. Деплой (две копии: ghost.apk = latest для скачивания, ghost_v{ver}.apk = архив)
$keyPath = "$env:USERPROFILE/.ssh/ghostecos_ed25519"
$remote  = "root@155.212.166.221"
$remoteDir = "/opt/ghostchat/apk"

Write-Host ">> scp $verName"
scp -i $keyPath -o StrictHostKeyChecking=no $src "${remote}:${remoteDir}/ghost.apk"
scp -i $keyPath -o StrictHostKeyChecking=no $src "${remote}:${remoteDir}/$verName"

Write-Host ">> Готово. Скачать: https://ghostecos.duckdns.org/apkextrawaki"
Write-Host "   Архив:        https://ghostecos.duckdns.org/apk/$verName"
