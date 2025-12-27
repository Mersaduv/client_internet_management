# دستورالعمل Rebuild برای رفع خطای WebView

## مشکل:
- خطای `ERR_CLEARTEXT_NOT_PERMITTED` 
- خطای `MissingPluginException` برای flutter_inappwebview

## راه‌حل:

### 1. پاک کردن کامل Build:
```powershell
flutter clean
```

### 2. حذف پوشه‌های cache:
```powershell
# حذف پوشه build
Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue

# حذف پوشه .dart_tool (اختیاری)
Remove-Item -Recurse -Force .dart_tool -ErrorAction SilentlyContinue
```

### 3. دریافت دوباره Dependencies:
```powershell
flutter pub get
```

### 4. Rebuild کامل:
```powershell
flutter run
```

### یا برای Build Release:
```powershell
flutter build apk --debug
```

## تغییرات اعمال شده:

1. ✅ اضافه شدن `android:usesCleartextTraffic="true"` به AndroidManifest.xml
2. ✅ بهبود مدیریت خطا در WebView
3. ✅ محافظت از متدهای canGoBack و canGoForward با try-catch

## نکته مهم:
بعد از تغییرات در AndroidManifest.xml **حتماً** باید `flutter clean` و سپس rebuild انجام شود.




