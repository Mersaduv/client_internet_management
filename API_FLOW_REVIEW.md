# بررسی فرایند کار با API از ورود تا تنظیم سرعت

## 📋 خلاصه فرایند

این سند فرایند کامل کار با MikroTik API را از مرحله ورود تا تنظیم سرعت بررسی می‌کند.

---

## 🔐 مرحله 1: ورود (Login)

### 1.1. صفحه ورود (`login_screen.dart`)

**مسیر:** `lib/screens/login_screen.dart`

**فرایند:**
1. کاربر نام کاربری و رمز عبور را وارد می‌کند
2. با کلیک روی دکمه "ورود"، تابع `_handleLogin()` فراخوانی می‌شود
3. تنظیمات روتر (host, port, useSsl) از `SettingsService` دریافت می‌شود
4. یک `MikroTikConnection` با اطلاعات کاربر و تنظیمات ایجاد می‌شود

```dart
// خط 72-78: ایجاد اتصال
final connection = MikroTikConnection(
  host: settings['host'] as String,
  port: settings['port'] as int,
  username: _usernameController.text.trim(),
  password: _passwordController.text,
  useSsl: settings['useSsl'] as bool,
);
```

### 1.2. اتصال از طریق Service Manager

**مسیر:** `lib/services/mikrotik_service_manager.dart`

**فرایند:**
1. یک instance از `MikroTikServiceManager` (Singleton) ایجاد می‌شود
2. متد `connect()` فراخوانی می‌شود
3. اتصال قبلی (در صورت وجود) بسته می‌شود
4. یک `MikroTikService` جدید ایجاد می‌شود

```dart
// خط 27-36: اتصال
final serviceManager = MikroTikServiceManager();
final success = await serviceManager.connect(connection);
```

### 1.3. اتصال در MikroTikService

**مسیر:** `lib/services/mikrotik_service.dart`

**فرایند:**
1. یک `RouterOSClientV2` با اطلاعات اتصال ایجاد می‌شود
2. متد `login()` فراخوانی می‌شود

```dart
// خط 16-38: اتصال به MikroTik
_client = RouterOSClientV2(
  address: connection.host,
  user: connection.username,
  password: connection.password,
  useSsl: connection.useSsl,
  port: connection.port,
);

final success = await _client!.login();
```

### 1.4. احراز هویت در RouterOSClientV2

**مسیر:** `lib/services/routeros_client_v2.dart`

**فرایند:**
1. یک `RouterOSClient` از پکیج `router_os_client` ایجاد می‌شود
2. متد `login()` برای اتصال و احراز هویت فراخوانی می‌شود
3. در صورت موفقیت، `_isConnected` و `_isAuthenticated` به `true` تنظیم می‌شوند

```dart
// خط 25-48: احراز هویت
_client = RouterOSClient(
  address: address,
  user: user,
  password: password,
  useSsl: useSsl,
  port: port,
);

final ok = await _client!.login();
if (ok) {
  _isConnected = true;
  _isAuthenticated = true;
}
```

### 1.5. ذخیره زمان لاگین

**مسیر:** `lib/screens/login_screen.dart`

**فرایند:**
- بعد از اتصال موفق، زمان لاگین در `SettingsService` ذخیره می‌شود
- کاربر به صفحه اصلی (`/home`) هدایت می‌شود

```dart
// خط 88-96: ذخیره زمان لاگین و انتقال
if (success) {
  await _settingsService.setLoginTimestamp();
  if (mounted) {
    Navigator.of(context).pushReplacementNamed('/home');
  }
}
```

---

## 🏠 مرحله 2: مقداردهی اولیه (Initialization)

### 2.1. مقداردهی Provider

**مسیر:** `lib/providers/clients_provider.dart`

**فرایند:**
بعد از ورود به صفحه اصلی، `ClientsProvider.initialize()` فراخوانی می‌شود:

```dart
// خط 486-499: مقداردهی اولیه
Future<void> initialize() async {
  await loadDeviceIp();           // دریافت IP دستگاه کاربر
  await loadRouterInfo();          // دریافت اطلاعات روتر
  await loadClients();             // بارگذاری لیست دستگاه‌های متصل
  await loadBannedClients();       // بارگذاری لیست دستگاه‌های مسدود شده
  _isNewConnectionsLocked = await _serviceManager.isNewConnectionsLocked();
  _updateAutoBanTimer();
  notifyListeners();
}
```

### 2.2. دریافت اطلاعات روتر

**مسیر:** `lib/services/mikrotik_service.dart`

**فرایند:**
- بعد از اتصال موفق، اطلاعات روتر (board-name, platform, version, uptime) دریافت می‌شود
- این اطلاعات در `MikroTikServiceManager` ذخیره می‌شود

---

## 📱 مرحله 3: نمایش دستگاه‌ها

### 3.1. بارگذاری دستگاه‌های متصل

**مسیر:** `lib/providers/clients_provider.dart` → `loadClients()`

**فرایند:**
1. `MikroTikServiceManager.getConnectedClients()` فراخوانی می‌شود
2. این متد به `MikroTikService.getConnectedClients()` ارجاع می‌دهد
3. در `MikroTikService`، دستگاه‌ها از منابع مختلف جمع‌آوری می‌شوند:
   - Hotspot Active Users (`/ip/hotspot/active/print`)
   - Wireless Clients (`/interface/wireless/registration-table/print`)
   - DHCP Leases (`/ip/dhcp-server/lease/print`)
   - PPP Active (`/ppp/active/print`)
   - ARP Table (`/ip/arp/print`)

### 3.2. تبدیل به ClientInfo

**فرایند:**
- داده‌های خام از MikroTik به مدل `ClientInfo` تبدیل می‌شوند
- هر دستگاه شامل اطلاعات زیر است:
  - IP Address
  - MAC Address
  - Host Name
  - Type (wireless, dhcp, hotspot, ppp)
  - Uptime
  - Bytes In/Out

---

## ⚡ مرحله 4: تنظیم سرعت (Set Speed)

### 4.1. انتخاب دستگاه

**مسیر:** `lib/screens/device_detail_screen.dart`

**فرایند:**
1. کاربر روی یک دستگاه کلیک می‌کند
2. صفحه جزئیات دستگاه (`DeviceDetailScreen`) باز می‌شود
3. کاربر می‌تواند سرعت را تغییر دهد

### 4.2. نمایش Dialog تنظیم سرعت

**مسیر:** `lib/screens/device_detail_screen.dart` (حدود خط 643)

**فرایند:**
1. کاربر روی دکمه "تنظیم سرعت" کلیک می‌کند
2. یک Dialog برای وارد کردن سرعت دانلود و آپلود نمایش داده می‌شود
3. کاربر مقادیر را وارد می‌کند (مثال: دانلود: 10M، آپلود: 2M)

### 4.3. فراخوانی setClientSpeed

**مسیر:** `lib/screens/device_detail_screen.dart` (خط 653-660)

**فرایند:**
1. فرمت سرعت به فرمت MikroTik تبدیل می‌شود: `upload/download`
2. `ClientsProvider.setClientSpeed()` فراخوانی می‌شود

```dart
// خط 653-660: تنظیم سرعت
final speedLimit = '${result['upload']}/${result['download']}';
final provider = Provider.of<ClientsProvider>(context, listen: false);
final success = await provider.setClientSpeed(
  widget.device.ipAddress!,
  speedLimit,
);
```

### 4.4. ارسال به MikroTikService

**مسیر:** `lib/providers/clients_provider.dart` (خط 443-468)

**فرایند:**
1. `ClientsProvider.setClientSpeed()` متد `MikroTikService.setClientSpeed()` را فراخوانی می‌کند
2. در صورت موفقیت، state به‌روزرسانی می‌شود

```dart
// خط 443-468: تنظیم سرعت در Provider
Future<bool> setClientSpeed(String target, String maxLimit) async {
  if (!_serviceManager.isConnected) {
    _errorMessage = 'اتصال برقرار نشده است.';
    notifyListeners();
    return false;
  }

  try {
    final success = await _serviceManager.service?.setClientSpeed(
      target,
      maxLimit,
    );

    if (success == true) {
      await refresh();
      return true;
    }
    return false;
  } catch (e) {
    _errorMessage = 'خطا در تنظیم سرعت: $e';
    notifyListeners();
    return false;
  }
}
```

### 4.5. تبدیل فرمت سرعت

**مسیر:** `lib/services/mikrotik_service.dart` (خط 1353-1399)

**فرایند:**
1. فرمت ورودی: `upload/download` (مثال: `2M/10M`)
2. تبدیل به بیت بر ثانیه:
   - `M` (مگابیت) → `value * 1000000`
   - `K` (کیلوبیت) → `value * 1000`
3. فرمت خروجی: `uploadBits/downloadBits` (مثال: `2000000/10000000`)

```dart
// خط 1359-1399: تبدیل فرمت
String maxLimitInBits = maxLimit;
if (maxLimit.contains('/')) {
  final parts = maxLimit.split('/');
  final uploadPart = parts[0].trim();
  final downloadPart = parts[1].trim();
  
  // تبدیل آپلود
  int uploadBits = 0;
  final uploadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(uploadPart);
  if (uploadMatch != null) {
    final value = int.tryParse(uploadMatch.group(1) ?? '0') ?? 0;
    final unit = (uploadMatch.group(2) ?? 'M').toUpperCase();
    if (unit == 'M') {
      uploadBits = value * 1000000; // Mbps به بیت
    } else if (unit == 'K') {
      uploadBits = value * 1000; // Kbps به بیت
    }
  }
  
  // تبدیل دانلود (مشابه آپلود)
  // ...
  
  maxLimitInBits = '$uploadBits/$downloadBits';
}
```

### 4.6. جستجوی Queue موجود

**مسیر:** `lib/services/mikrotik_service.dart` (خط 1401-1419)

**فرایند:**
1. لیست Queue های موجود از MikroTik دریافت می‌شود: `/queue/simple/print`
2. IP دستگاه با `target` هر queue مقایسه می‌شود
3. اگر queue موجود باشد، ID آن ذخیره می‌شود

```dart
// خط 1401-1419: جستجوی Queue
final queues = await _client!.talk(['/queue/simple/print']);
String? queueId;
final targetIp = target.split('/')[0].trim();

for (var queue in queues) {
  final queueTarget = queue['target']?.toString() ?? '';
  if (queueTarget.isEmpty) continue;
  
  final queueTargetIp = queueTarget.split('/')[0].trim();
  
  if (queueTargetIp == targetIp || 
      queueTarget == target || 
      queueTarget.startsWith('$targetIp/')) {
    queueId = queue['.id'];
    break;
  }
}
```

### 4.7. ایجاد یا به‌روزرسانی Queue

**مسیر:** `lib/services/mikrotik_service.dart` (خط 1421-1430)

**فرایند:**
- **اگر Queue موجود باشد:** با `/queue/simple/set` به‌روزرسانی می‌شود
- **اگر Queue موجود نباشد:** با `/queue/simple/add` ایجاد می‌شود

```dart
// خط 1421-1430: ایجاد یا به‌روزرسانی Queue
final targetWithSubnet = target.contains('/') ? target : '$target/32';

if (queueId != null) {
  // به‌روزرسانی queue موجود
  await _client!.talk([
    '/queue/simple/set',
    '=.id=$queueId',
    '=max-limit=$maxLimitInBits'
  ]);
} else {
  // ایجاد queue جدید
  await _client!.talk([
    '/queue/simple/add',
    '=target=$targetWithSubnet',
    '=max-limit=$maxLimitInBits'
  ]);
}
```

### 4.8. ایجاد Static IP Lease (اختیاری)

**مسیر:** `lib/services/mikrotik_service.dart` (خط 1432-1464)

**فرایند:**
1. MAC Address از DHCP Leases یا ARP Table پیدا می‌شود
2. یک Static IP Lease ایجاد می‌شود تا IP دستگاه ثابت بماند
3. این کار اختیاری است و در صورت خطا، ادامه می‌یابد

```dart
// خط 1432-1464: ایجاد Static IP
try {
  // پیدا کردن MAC address از IP
  String? macAddress;
  final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
  for (var lease in dhcpLeases) {
    if (lease['address'] == targetIp) {
      macAddress = lease['mac-address'];
      break;
    }
  }
  
  // اگر در DHCP پیدا نشد، در ARP table جستجو کن
  if (macAddress == null) {
    final arpEntries = await _client!.talk(['/ip/arp/print']);
    for (var arp in arpEntries) {
      if (arp['address'] == targetIp) {
        macAddress = arp['mac-address'];
        break;
      }
    }
  }

  if (macAddress != null) {
    await _createOrUpdateStaticLease(
      targetIp,
      macAddress,
      comment: 'Static IP - Speed Limited via Flutter App',
    );
  }
} catch (e) {
  // ignore errors - Static IP optional است
}
```

### 4.9. به‌روزرسانی UI

**مسیر:** `lib/screens/device_detail_screen.dart` (خط 662-704)

**فرایند:**
1. در صورت موفقیت، یک SnackBar سبز نمایش داده می‌شود
2. سرعت فعلی دوباره بارگذاری می‌شود (`_loadSpeedLimit()`)
3. در صورت خطا، یک SnackBar قرمز با پیام خطا نمایش داده می‌شود

```dart
// خط 662-704: نمایش نتیجه
if (success) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'سرعت تنظیم شد: دانلود ${result['download']} - آپلود ${result['upload']}',
            ),
          ),
        ],
      ),
      backgroundColor: Colors.green,
      behavior: SnackBarBehavior.floating,
    ),
  );
  _loadSpeedLimit();
} else {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.error, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'خطا: ${provider.errorMessage ?? "خطا در تنظیم سرعت"}',
            ),
          ),
        ],
      ),
      backgroundColor: Colors.red,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
```

---

## 🔄 خلاصه جریان داده

```
1. LoginScreen
   ↓
2. MikroTikServiceManager.connect()
   ↓
3. MikroTikService.connect()
   ↓
4. RouterOSClientV2.login()
   ↓
5. RouterOSClient.login() [پکیج router_os_client]
   ↓
6. اتصال برقرار شد ✓
   ↓
7. ClientsProvider.initialize()
   ↓
8. loadClients() → MikroTikService.getConnectedClients()
   ↓
9. نمایش لیست دستگاه‌ها
   ↓
10. کاربر روی دستگاه کلیک می‌کند
   ↓
11. DeviceDetailScreen → Dialog تنظیم سرعت
   ↓
12. ClientsProvider.setClientSpeed()
   ↓
13. MikroTikService.setClientSpeed()
   ↓
14. تبدیل فرمت سرعت (M/K → bits)
   ↓
15. جستجوی Queue موجود
   ↓
16. ایجاد یا به‌روزرسانی Queue در MikroTik
   ↓
17. ایجاد Static IP Lease (اختیاری)
   ↓
18. به‌روزرسانی UI
```

---

## ⚠️ نکات مهم

### 1. مدیریت اتصال
- اتصال در `MikroTikServiceManager` به صورت Singleton نگه‌داری می‌شود
- در صورت قطع اتصال، باید دوباره لاگین انجام شود

### 2. فرمت سرعت
- فرمت ورودی: `upload/download` (مثال: `2M/10M`)
- فرمت MikroTik: `uploadBits/downloadBits` (مثال: `2000000/10000000`)
- تبدیل: `M` = `* 1000000`, `K` = `* 1000`

### 3. Queue Management
- اگر Queue برای IP موجود باشد، به‌روزرسانی می‌شود
- اگر Queue موجود نباشد، یک Queue جدید ایجاد می‌شود
- Target به صورت `IP/32` تنظیم می‌شود

### 4. Static IP Lease
- ایجاد Static IP Lease اختیاری است
- در صورت خطا، فرایند ادامه می‌یابد
- هدف: ثابت نگه داشتن IP دستگاه

### 5. Error Handling
- در هر مرحله، خطاها catch می‌شوند
- پیام خطا به کاربر نمایش داده می‌شود
- در صورت خطا، state به‌روزرسانی نمی‌شود

---

## 📝 نتیجه‌گیری

فرایند کار با API از ورود تا تنظیم سرعت به صورت زیر است:

1. **ورود:** کاربر اطلاعات روتر را وارد می‌کند و اتصال برقرار می‌شود
2. **مقداردهی اولیه:** اطلاعات روتر و دستگاه‌ها بارگذاری می‌شوند
3. **نمایش دستگاه‌ها:** لیست دستگاه‌های متصل نمایش داده می‌شود
4. **تنظیم سرعت:** کاربر سرعت را انتخاب می‌کند و Queue در MikroTik ایجاد/به‌روزرسانی می‌شود

همه مراحل با مدیریت خطا و به‌روزرسانی UI همراه هستند.

