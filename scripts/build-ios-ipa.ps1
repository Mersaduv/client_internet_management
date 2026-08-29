# Build iOS IPA via GitHub Actions and save it to dist/ios/
$ErrorActionPreference = "Stop"

$repo = "Mersaduv/client_internet_management"
$root = Split-Path $PSScriptRoot -Parent
$distDir = Join-Path $root "dist\ios"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Write-Host "=== Ariyabod iOS Build ===" -ForegroundColor Cyan
Write-Host ""

$flutterHelp = flutter build -h 2>&1 | Out-String
if ($flutterHelp -notmatch "ios") {
    Write-Host "Note: flutter build ios is not available on Windows." -ForegroundColor Yellow
    Write-Host "Building on GitHub Actions (macOS runner) ..." -ForegroundColor Yellow
    Write-Host ""
}

# Read version from pubspec.yaml
$pubspec = Get-Content (Join-Path $root "pubspec.yaml") -Raw
if ($pubspec -match '(?m)^version:\s*([0-9.]+)\+') {
    $version = $Matches[1]
} else {
    throw "Could not read version from pubspec.yaml"
}

$tag = "v$version-ios"
Write-Host "Version: $version" -ForegroundColor Cyan
Write-Host "Tag: $tag" -ForegroundColor Cyan
Write-Host ""

# Push workflow changes if any
$branch = git -C $root branch --show-current
$ahead = git -C $root rev-list --count "origin/$branch..HEAD" 2>$null
if ($LASTEXITCODE -eq 0 -and $ahead -ne "0") {
    Write-Host "Pushing $ahead commit(s) to origin/$branch ..." -ForegroundColor Yellow
    git -C $root push -u origin "HEAD:$branch"
}

# Create and push tag to trigger build
$existingTag = git -C $root tag -l $tag
if ($existingTag) {
    $tag = "${tag}-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "Tag already exists, using: $tag" -ForegroundColor Yellow
}
git -C $root tag $tag
git -C $root push origin $tag
Write-Host "Pushed tag $tag" -ForegroundColor Green
Write-Host ""

# Wait for GitHub Actions build
Write-Host "Waiting for GitHub Actions build (up to 20 min) ..." -ForegroundColor Yellow
$deadline = (Get-Date).AddMinutes(20)
$runId = $null
while ((Get-Date) -lt $deadline) {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/workflows/ios-ipa.yml/runs?per_page=5"
    $run = $runs.workflow_runs | Where-Object { $_.head_branch -eq $tag } | Select-Object -First 1
    if ($run) {
        $runId = $run.id
        if ($run.status -eq "completed") {
            if ($run.conclusion -eq "success") {
                Write-Host "Build succeeded (run #$($run.run_number))." -ForegroundColor Green
                break
            }
            # Artifact may exist even if release step failed
            $artifacts = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$($run.id)/artifacts"
            if ($artifacts.total_count -gt 0) {
                Write-Host "Build finished with issues, but artifact is available." -ForegroundColor Yellow
                break
            }
            throw "Build failed: $($run.html_url)"
        }
        Write-Host "  Status: $($run.status) ..." -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 20
}
if (-not $runId -or (Get-Date) -ge $deadline) {
    throw "Build timed out. Check: https://github.com/$repo/actions"
}

# Wait for release asset
Write-Host "Waiting for release asset ..." -ForegroundColor Yellow
$ipaName = "Ariyabod-v$version-unsigned.ipa"
$downloadUrl = "https://github.com/$repo/releases/download/$tag/$ipaName"
$outFile = Join-Path $distDir $ipaName
$assetDeadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $assetDeadline) {
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $outFile -ErrorAction Stop
        Write-Host ""
        Write-Host "IPA saved to:" -ForegroundColor Green
        Write-Host "  $outFile"
        Write-Host ""
        exit 0
    } catch {
        Start-Sleep -Seconds 10
    }
}

throw "Release asset not found at $downloadUrl"
