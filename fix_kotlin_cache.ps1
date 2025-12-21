# اسکریپت PowerShell برای رفع مشکل Kotlin Cache

Write-Host "در حال پاک کردن cache های Kotlin..." -ForegroundColor Yellow

# 1. توقف Gradle Daemon
Write-Host "`n1. توقف Gradle Daemon..." -ForegroundColor Cyan
cd android
.\gradlew --stop
cd ..

# 2. پاک کردن build folder
Write-Host "`n2. پاک کردن build folder..." -ForegroundColor Cyan
if (Test-Path "build") {
    Remove-Item -Recurse -Force "build" -ErrorAction SilentlyContinue
    Write-Host "   ✓ build folder حذف شد" -ForegroundColor Green
}

# 3. پاک کردن Kotlin cache ها
Write-Host "`n3. پاک کردن Kotlin cache ها..." -ForegroundColor Cyan
$kotlinCachePaths = @(
    "build\shared_preferences_android\kotlin",
    "build\flutter_inappwebview_android\kotlin",
    "android\.gradle",
    "android\app\build"
)

foreach ($path in $kotlinCachePaths) {
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
        Write-Host "   ✓ $path حذف شد" -ForegroundColor Green
    }
}

# 4. پاک کردن Flutter build
Write-Host "`n4. پاک کردن Flutter build..." -ForegroundColor Cyan
flutter clean

# 5. دریافت dependencies
Write-Host "`n5. دریافت dependencies..." -ForegroundColor Cyan
flutter pub get

Write-Host "`n✓ تمام cache ها پاک شدند!" -ForegroundColor Green
Write-Host "`nحالا می‌توانید با دستور زیر برنامه را اجرا کنید:" -ForegroundColor Yellow
Write-Host "flutter run" -ForegroundColor White



