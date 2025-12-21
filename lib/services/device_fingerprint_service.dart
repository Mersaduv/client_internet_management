import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_fingerprint.dart';
import '../models/client_info.dart';

/// سرویس برای مدیریت Device Fingerprints
/// 
/// این سرویس Device Fingerprints مسدود شده را ذخیره می‌کند و
/// هنگام بررسی دستگاه‌های متصل، آن‌ها را با لیست مسدود شده‌ها مقایسه می‌کند.
class DeviceFingerprintService {
  static const String _bannedFingerprintsKey = 'banned_device_fingerprints';
  static final DeviceFingerprintService _instance = DeviceFingerprintService._internal();
  factory DeviceFingerprintService() => _instance;
  DeviceFingerprintService._internal();

  /// ذخیره Device Fingerprint مسدود شده
  Future<void> saveBannedFingerprint(DeviceFingerprint fingerprint) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bannedList = await getBannedFingerprints();
      
      // بررسی اینکه آیا قبلاً ذخیره شده است
      bool exists = false;
      for (var existing in bannedList) {
        if (existing.matches(fingerprint)) {
          exists = true;
          break;
        }
      }
      
      if (!exists) {
        // افزودن زمان مسدود شدن
        final fingerprintWithTime = DeviceFingerprint(
          hostname: fingerprint.hostname,
          macVendor: fingerprint.macVendor,
          deviceType: fingerprint.deviceType,
          ssid: fingerprint.ssid,
          macAddress: fingerprint.macAddress,
          ipAddress: fingerprint.ipAddress,
          bannedAt: DateTime.now(),
          comment: fingerprint.comment,
        );
        
        bannedList.add(fingerprintWithTime);
        
        // ذخیره در SharedPreferences
        final jsonList = bannedList.map((f) => f.toMap()).toList();
        await prefs.setString(_bannedFingerprintsKey, jsonEncode(jsonList));
      }
    } catch (e) {
      // ignore errors
    }
  }

  /// دریافت لیست Device Fingerprints مسدود شده
  Future<List<DeviceFingerprint>> getBannedFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_bannedFingerprintsKey);
      
      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }
      
      final jsonList = jsonDecode(jsonString) as List;
      return jsonList
          .map((json) => DeviceFingerprint.fromMap(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// حذف Device Fingerprint از لیست مسدود شده‌ها
  /// حذف همه Device Fingerprint های مطابق (هم دو طرفه)
  Future<void> removeBannedFingerprint(DeviceFingerprint fingerprint) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bannedList = await getBannedFingerprints();
      
      // حذف همه Device Fingerprint های مطابق (هم دو طرفه)
      // این اطمینان می‌دهد که همه نسخه‌های ممکن حذف می‌شوند
      bannedList.removeWhere((existing) {
        // بررسی دو طرفه: fingerprint.matches(existing) یا existing.matches(fingerprint)
        return fingerprint.matches(existing) || existing.matches(fingerprint);
      });
      
      // ذخیره مجدد
      final jsonList = bannedList.map((f) => f.toMap()).toList();
      await prefs.setString(_bannedFingerprintsKey, jsonEncode(jsonList));
    } catch (e) {
      // ignore errors
    }
  }

  /// بررسی اینکه آیا یک دستگاه مسدود شده است یا نه
  /// 
  /// این تابع Device Fingerprint دستگاه را محاسبه می‌کند و
  /// با لیست مسدود شده‌ها مقایسه می‌کند.
  Future<bool> isDeviceBanned(ClientInfo client) async {
    try {
      // ایجاد Device Fingerprint از ClientInfo
      final fingerprint = DeviceFingerprint.fromClientInfo(
        client.ipAddress,
        client.macAddress,
        client.hostName,
        client.ssid,
      );
      
      // دریافت لیست مسدود شده‌ها
      final bannedList = await getBannedFingerprints();
      
      // مقایسه با هر یک از مسدود شده‌ها
      for (var banned in bannedList) {
        if (fingerprint.matches(banned)) {
          return true;
        }
      }
      
      return false;
    } catch (e) {
      return false;
    }
  }

  /// بررسی اینکه آیا یک Device Fingerprint مسدود شده است
  Future<bool> isFingerprintBanned(DeviceFingerprint fingerprint) async {
    try {
      final bannedList = await getBannedFingerprints();
      
      for (var banned in bannedList) {
        if (fingerprint.matches(banned)) {
          return true;
        }
      }
      
      return false;
    } catch (e) {
      return false;
    }
  }

  /// پیدا کردن Device Fingerprint مسدود شده که با ClientInfo مطابقت دارد
  Future<DeviceFingerprint?> findBannedFingerprint(ClientInfo client) async {
    try {
      final fingerprint = DeviceFingerprint.fromClientInfo(
        client.ipAddress,
        client.macAddress,
        client.hostName,
        client.ssid,
      );
      
      final bannedList = await getBannedFingerprints();
      
      for (var banned in bannedList) {
        if (fingerprint.matches(banned)) {
          return banned;
        }
      }
      
      return null;
    } catch (e) {
      return null;
    }
  }

  /// پاک کردن همه Device Fingerprints مسدود شده
  Future<void> clearAllBannedFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_bannedFingerprintsKey);
    } catch (e) {
      // ignore errors
    }
  }

  /// دریافت تعداد Device Fingerprints مسدود شده
  Future<int> getBannedCount() async {
    final bannedList = await getBannedFingerprints();
    return bannedList.length;
  }
}
