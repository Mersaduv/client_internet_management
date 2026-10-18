# Build iOS IPA via GitHub Actions (requires push to GitHub)
$ErrorActionPreference = "Stop"

Write-Host "=== Ariyabod iOS Build ===" -ForegroundColor Cyan
Write-Host ""

# iOS cannot be built on Windows; macOS runner on GitHub is required.
$flutterHelp = flutter build -h 2>&1 | Out-String
if ($flutterHelp -notmatch "ios") {
    Write-Host "Note: flutter build ios is not available on Windows." -ForegroundColor Yellow
    Write-Host "The IPA will be built on GitHub Actions (macOS runner)." -ForegroundColor Yellow
    Write-Host ""
}

$branch = git branch --show-current
$ahead = (git rev-list --count "origin/$branch..HEAD" 2>$null)
if ($LASTEXITCODE -ne 0) { $ahead = "?" }

if ($ahead -ne "0" -and $ahead -ne "?") {
    Write-Host "You have $ahead unpushed commit(s). Pushing to origin/$branch ..." -ForegroundColor Yellow
    git push -u origin "HEAD:$branch"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Push failed. Push manually, then run the workflow from GitHub Actions." -ForegroundColor Red
        exit 1
    }
    Write-Host "Push OK." -ForegroundColor Green
} else {
    Write-Host "Branch is up to date with remote (or remote not configured)." -ForegroundColor Green
}

$repoUrl = git remote get-url origin 2>$null
if ($repoUrl -match "github\.com[:/](.+?)(?:\.git)?$") {
    $repoPath = $Matches[1]
    $actionsUrl = "https://github.com/$repoPath/actions/workflows/ios-ipa.yml"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "1. Open: $actionsUrl"
    Write-Host "2. Click 'Run workflow' -> branch: $branch -> Run"
    Write-Host "3. Wait ~10-20 min, then download artifact: Ariyabod-ios-unsigned-ipa"
    Write-Host "4. Extract Ariyabod-unsigned.ipa and install with Sideloadly"
    Write-Host ""
    Start-Process $actionsUrl
} else {
    Write-Host "Open GitHub -> Actions -> 'Build iOS IPA (unsigned)' -> Run workflow"
}
