# Download the latest iOS IPA release into dist/ios/
$ErrorActionPreference = "Stop"

$repo = "Mersaduv/client_internet_management"
$distDir = Join-Path $PSScriptRoot "..\dist\ios" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $distDir) {
    $distDir = Join-Path (Split-Path $PSScriptRoot -Parent) "dist\ios"
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    $distDir = (Resolve-Path $distDir).Path
}

Write-Host "Fetching latest iOS release from $repo ..." -ForegroundColor Cyan

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest"
$asset = $release.assets | Where-Object { $_.name -like "*.ipa" } | Select-Object -First 1
if (-not $asset) {
    throw "No IPA asset found in latest release."
}

$outFile = Join-Path $distDir $asset.name
Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 2)) MB) ..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $outFile

Write-Host ""
Write-Host "IPA saved to:" -ForegroundColor Green
Write-Host "  $outFile"
Write-Host ""
Write-Host "Install with Sideloadly on iPhone." -ForegroundColor Cyan
