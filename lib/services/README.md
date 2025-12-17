# سرویس MikroTik RouterOS API v6

این سرویس برای اتصال مستقیم به MikroTik RouterOS API v6 از طریق پروتکل Binary API پیاده‌سازی شده است.

## ویژگی‌ها

- ✅ اتصال مستقیم به RouterOS بدون نیاز به سرویس Python
- ✅ پشتیبانی از SSL (پورت 8729)
- ✅ احراز هویت با challenge-response
- ✅ تمام endpointهای `/api/clients/*` پیاده‌سازی شده

## نحوه استفاده

### 1. اتصال به MikroTik

```dart
import 'package:internet_management/models/mikrotik_connection.dart';
import 'package:internet_management/services/mikrotik_service.dart';

final service = MikroTikService();

final connection = MikroTikConnection(
  host: '192.168.88.1',
  port: 8728,
  username: 'admin',
  password: 'password',
  useSsl: false, // true برای SSL
);

try {
  final success = await service.connect(connection);
  if (success) {
    print('اتصال موفقیت‌آمیز بود');
  } else {
    print('اتصال ناموفق');
  }
} catch (e) {
  print('خطا: $e');
}
```

### 2. دریافت همه کلاینت‌ها

```dart
try {
  final result = await service.getAllClients();
  print('تعداد کلاینت‌ها: ${result['total_count']}');
  
  final clients = result['clients'] as List;
  for (var client in clients) {
    print('نوع: ${client['type']}, IP: ${client['ip_address']}');
  }
} catch (e) {
  print('خطا: $e');
}
```

### 3. دریافت کلاینت‌های متصل

```dart
try {
  final result = await service.getConnectedClients();
  final clients = result['clients'] as List;
  // پردازش کلاینت‌ها
} catch (e) {
  print('خطا: $e');
}
```

### 4. مسدود کردن کلاینت

```dart
try {
  final success = await service.banClient('192.168.88.100');
  if (success) {
    print('کلاینت مسدود شد');
  }
} catch (e) {
  print('خطا: $e');
}
```

### 5. رفع مسدودیت

```dart
try {
  final success = await service.unbanClient('192.168.88.100');
  if (success) {
    print('مسدودیت رفع شد');
  }
} catch (e) {
  print('خطا: $e');
}
```

### 6. تنظیم سرعت

```dart
try {
  final success = await service.setClientSpeed(
    '192.168.88.100',
    '10M/10M', // max-limit
  );
  if (success) {
    print('سرعت تنظیم شد');
  }
} catch (e) {
  print('خطا: $e');
}
```

### 7. بستن اتصال

```dart
service.disconnect();
```

## متدهای موجود

- `connect(MikroTikConnection)` - اتصال به RouterOS
- `getAllClients()` - دریافت همه کلاینت‌ها (Hotspot, Wireless, DHCP, PPP)
- `getClientsDetailed()` - دریافت جزئیات کامل با ARP و Queue
- `getConnectedClients()` - دریافت فقط کلاینت‌های متصل
- `banClient(String ipAddress, {String? macAddress})` - مسدود کردن
- `unbanClient(String ipAddress)` - رفع مسدودیت
- `getBannedClients()` - دریافت لیست مسدود شده‌ها
- `setClientSpeed(String target, String maxLimit)` - تنظیم سرعت
- `getClientSpeed(String target)` - دریافت سرعت
- `checkIp(String ipAddress)` - بررسی IP
- `disconnect()` - بستن اتصال

## نکات مهم

1. **RouterOS v6**: این سرویس فقط برای RouterOS v6 طراحی شده است (Binary API)
2. **SSL**: برای استفاده از SSL، `useSsl: true` تنظیم کنید (پورت 8729)
3. **مدیریت خطا**: همیشه از try-catch استفاده کنید
4. **بستن اتصال**: پس از استفاده، حتماً `disconnect()` را فراخوانی کنید

