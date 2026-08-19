# Build APK lalu unggah ke GitHub Releases (in-app update).
# Pemakaian:  .\scripts\publish-release.ps1
param(
    [string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$pubspec = Get-Content -Raw "pubspec.yaml"
if ($pubspec -notmatch '(?m)^version:\s*([0-9.]+)\+(\d+)') {
    throw "version: x.y.z+build tidak ditemukan di pubspec.yaml"
}
$versionName = $Matches[1]
$versionCode = $Matches[2]
$tag = "v$versionName-$versionCode"
$apkName = "yt-downloader.apk"

Write-Host "Building $tag ..."
flutter pub get
flutter build apk --release

$src = Join-Path $Root "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $src)) { throw "APK tidak ketemu: $src" }
Copy-Item $src $apkName -Force

$remote = gh repo view --json nameWithOwner -q .nameWithOwner
$url = "https://github.com/$remote/releases/download/$tag/$apkName"
$notesText = if ($Notes) { $Notes } else { "YT Downloader $versionName" }

$latest = @{
    version     = $versionName
    versionCode = [int]$versionCode
    notes       = $notesText
    apk         = $apkName
    url         = $url
} | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $Root "latest.json"), $latest)

$exists = $true
gh release view $tag 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { $exists = $false }

if ($exists) {
    Write-Host "Release $tag sudah ada — upload ulang asset"
    gh release upload $tag $apkName latest.json --clobber
} else {
    gh release create $tag $apkName latest.json --title "YT Downloader v$versionName" --notes $notesText --latest
}

Write-Host "Selesai: https://github.com/$remote/releases/tag/$tag"
