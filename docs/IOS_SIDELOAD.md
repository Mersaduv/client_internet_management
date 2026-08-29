# نصب Ariyabod روی iPhone بدون App Store

از آنجا که کامپایل iOS فقط روی macOS ممکن است، ساخت فایل `.ipa` روی GitHub Actions (رانر macOS) انجام می‌شود و سپس روی ویندوز با یک ابزار Sideload امضا و نصب می‌گردد.

## مرحله ۱ — ساخت IPA

1. تغییرات را push کنید (فایل `.github/workflows/ios-ipa.yml` باید در ریپو باشد).
2. در GitHub وارد تب **Actions** شوید، workflow با نام **Build iOS IPA (unsigned)** را انتخاب و **Run workflow** را بزنید.
   - جایگزین: تگ بزنید تا خودکار اجرا شود: `git tag v1.3.0 && git push origin v1.3.0`
3. پس از پایان build (حدود ۱۰–۲۰ دقیقه)، از بخش **Artifacts** فایل `Ariyabod-ios-unsigned-ipa` را دانلود و از حالت zip خارج کنید تا `Ariyabod-unsigned.ipa` به دست آید.

## مرحله ۲ — امضا و نصب روی آیفون

نیازمندی‌ها روی ویندوز:

- iTunes نسخه دسکتاپ (نه نسخه Microsoft Store) و iCloud for Windows نسخه دسکتاپ
- کابل USB و یک Apple ID (حساب رایگان کافی است)
- ابزار Sideload مانند **Sideloadly** یا **AltStore**

مراحل:

1. آیفون را با کابل وصل کنید و در آیفون گزینه **Trust** را بزنید.
2. در Sideloadly فایل `.ipa` را انتخاب کنید، Apple ID را وارد کنید و **Start** را بزنید.
   - اگر Two-Factor Authentication فعال است، باید یک **App-Specific Password** از حساب اپل بسازید و همان را وارد کنید.
3. پس از نصب، در آیفون به مسیر **Settings → General → VPN & Device Management** بروید و پروفایل مربوط به Apple ID خود را **Trust** کنید.
4. برنامه را اجرا کنید.

## نکات مهم

- با Apple ID رایگان، امضا فقط **۷ روز** اعتبار دارد و باید مجدداً Sideload شود. با حساب Developer پرداختی (سالانه ۹۹ دلار) اعتبار ۱ سال است.
- حساب رایگان حداکثر **۳ اپ** به‌طور همزمان و **۱۰ App ID در ۷ روز** اجازه می‌دهد.
- Bundle ID برنامه: `com.ariyabod.internetmanagement`
- در اولین اجرا، iOS دو مجوز می‌پرسد که برای کار برنامه لازم است:
  - **Local Network** برای اتصال به روتر MikroTik در شبکه محلی
  - **Location** برای تشخیص نام Wi-Fi و آدرس Gateway
