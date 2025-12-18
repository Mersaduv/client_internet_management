# راهنمای رفع مشکل Kotlin Incremental Cache

## مشکل:
خطاهای `Could not close incremental caches` و `Storage is already registered` هنگام build کردن پروژه.

## راه‌حل سریع:

### روش 1: استفاده از اسکریپت PowerShell (پیشنهادی)
```powershell
.\fix_kotlin_cache.ps1
```

### روش 2: دستورات دستی

#### 1. توقف Gradle Daemon:
```powershell
cd android
.\gradlew --stop
cd ..
```

#### 2. پاک کردن cache ها:
```powershell
# پاک کردن build
flutter clean

# پاک کردن cache های Kotlin
Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force android\.gradle -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force android\app\build -ErrorAction SilentlyContinue
```

#### 3. دریافت دوباره dependencies:
```powershell
flutter pub get
```

#### 4. اجرای مجدد:
```powershell
flutter run
```

## تنظیمات اعمال شده:

در `android/gradle.properties` اضافه شده:
- `kotlin.incremental=false` - غیرفعال کردن incremental compilation
- `org.gradle.caching=true` - فعال کردن build cache
- `org.gradle.parallel=true` - build موازی
- `org.gradle.configureondemand=true` - پیکربندی on-demand

## نکات مهم:

1. **این خطاها معمولاً warning هستند** و برنامه همچنان کار می‌کند
2. اگر مشکل ادامه داشت، `kotlin.incremental=false` را در `gradle.properties` فعال کنید
3. برای build سریع‌تر بعد از رفع مشکل، می‌توانید `kotlin.incremental=true` را دوباره فعال کنید

## اگر مشکل ادامه داشت:

1. Restart کردن Android Studio / IDE
2. Restart کردن کامپیوتر
3. بررسی اینکه هیچ فایل lock شده‌ای در build folder وجود نداشته باشد


