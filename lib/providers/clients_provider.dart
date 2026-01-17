import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/client_info.dart';
import '../services/mikrotik_service_manager.dart';

/// Provider برای مدیریت state کلاینت‌ها به صورت real-time
class ClientsProvider extends ChangeNotifier {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();

  // State variables
  bool _isLoading = false;
  bool _isDataComplete = false;
  List<ClientInfo> _clients = [];
  List<Map<String, dynamic>> _bannedClients = [];
  String? _errorMessage;
  String? _deviceIp;
  bool _isRefreshing = false;
  Map<String, dynamic>? _routerInfo;
  bool _isNewConnectionsLocked = false;
  // Map برای ذخیره وضعیت Static دستگاه‌ها (key: IP یا MAC, value: bool)
  final Map<String, bool> _deviceStaticStatus = {};
  // Map برای ذخیره وضعیت فیلترینگ شبکه‌های اجتماعی (key: deviceIp, value: Map<String, bool>)
  final Map<String, Map<String, bool>> _deviceFilterStatus = {};

  // Timer برای بررسی دوره‌ای دستگاه‌های جدید (real-time auto-ban)
  Timer? _autoBanCheckTimer;
  static const Duration _autoBanCheckInterval = Duration(seconds: 5); // هر 5 ثانیه یکبار بررسی

  // Getters
  bool get isLoading => _isLoading;
  bool get isDataComplete => _isDataComplete;
  List<ClientInfo> get clients => _clients;
  List<Map<String, dynamic>> get bannedClients => _bannedClients;
  String? get errorMessage => _errorMessage;
  String? get deviceIp => _deviceIp;
  bool get isRefreshing => _isRefreshing;
  bool get isConnected => _serviceManager.isConnected;
  Map<String, dynamic>? get routerInfo => _routerInfo;
  bool get isNewConnectionsLocked => _isNewConnectionsLocked;

  /// بارگذاری IP دستگاه
  Future<void> loadDeviceIp({bool forceRefresh = false}) async {
    // اگر IP قبلاً لود شده و force refresh نیست، دوباره لود نکن
    if (_deviceIp != null && !_isRefreshing && !forceRefresh) {
      return;
    }

    try {
      final ip = await _serviceManager.getDeviceIp().timeout(
        const Duration(seconds: 10), // افزایش timeout برای اطمینان از تشخیص صحیح
        onTimeout: () => null,
      );
      if (ip != null) {
        // همیشه IP را به‌روزرسانی کن (حتی اگر تغییر نکرده باشد)
        // چون ممکن است IP قبلی اشتباه تشخیص داده شده باشد
        _deviceIp = ip;
        notifyListeners();
      }
    } catch (e) {
      // در صورت خطا، IP قبلی را حفظ کن
    }
  }

  /// بارگذاری اطلاعات روتر (board-name و platform)
  Future<void> loadRouterInfo() async {
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final routerInfo = await _serviceManager.getRouterInfo();
      if (routerInfo != null) {
        _routerInfo = routerInfo;
        notifyListeners();
      }
    } catch (e) {
      // ignore errors - router info optional است
    }
  }

  /// بارگذاری لیست کلاینت‌های متصل
  Future<void> loadClients({bool showLoading = true}) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است. لطفاً دوباره وارد شوید.';
      _isLoading = false;
      _isDataComplete = false;
      notifyListeners();
      return;
    }

    if (showLoading) {
      _isLoading = true;
      _isDataComplete = false;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      final result = await _serviceManager.getConnectedClients();
      final clientsList = (result['clients'] as List)
          .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
          .toList();

      // بررسی کامل بودن داده‌ها
      bool dataComplete = true;
      if (clientsList.isEmpty) {
        dataComplete = true;
      } else {
        int completeCount = 0;
        for (var client in clientsList) {
          if ((client.ipAddress != null && client.ipAddress!.isNotEmpty) ||
              (client.hostName != null && client.hostName!.isNotEmpty) ||
              (client.user != null && client.user!.isNotEmpty) ||
              (client.name != null && client.name!.isNotEmpty)) {
            completeCount++;
          }
        }

        if (completeCount < (clientsList.length * 0.5).ceil() &&
            clientsList.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 800));
          final retryResult = await _serviceManager.getConnectedClients();
          final retryClientsList = (retryResult['clients'] as List)
              .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
              .toList();

          completeCount = 0;
          for (var client in retryClientsList) {
            if ((client.ipAddress != null && client.ipAddress!.isNotEmpty) ||
                (client.hostName != null && client.hostName!.isNotEmpty) ||
                (client.user != null && client.user!.isNotEmpty) ||
                (client.name != null && client.name!.isNotEmpty)) {
              completeCount++;
            }
          }

          if (completeCount >= (retryClientsList.length * 0.5).ceil() ||
              retryClientsList.isEmpty) {
            clientsList.clear();
            clientsList.addAll(retryClientsList);
            dataComplete = true;
          } else {
            await Future.delayed(const Duration(milliseconds: 500));
            final finalResult = await _serviceManager.getConnectedClients();
            final finalClientsList = (finalResult['clients'] as List)
                .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
                .toList();
            clientsList.clear();
            clientsList.addAll(finalClientsList);
            dataComplete = true;
          }
        }
      }

      // بررسی وضعیت قفل اتصال جدید
      bool wasLocked = _isNewConnectionsLocked;
      try {
        _isNewConnectionsLocked = await _serviceManager.isNewConnectionsLocked();
        notifyListeners();
        
        // اگر وضعیت قفل تغییر کرد، Timer را به‌روزرسانی کن
        if (wasLocked != _isNewConnectionsLocked) {
          _updateAutoBanTimer();
        }
      } catch (e) {
        // ignore
      }

      // اگر قفل فعال است، بررسی و مسدود کردن دستگاه‌های جدید
      // هر دستگاهی که بعد از فعال شدن قفل وصل شود (حتی اگر قبلاً وصل شده بوده) باید مسدود شود
      if (_isNewConnectionsLocked) {
        try {
          // دریافت لیست MAC ها و IP های مجاز (لیست اولیه در زمان فعال شدن قفل)
          final allowedMacs = await _serviceManager.service?.getAllowedMacsForLock() ?? <String>{};
          final allowedIps = await _serviceManager.service?.getAllowedIpsForLock() ?? <String>{};
          
          // اضافه کردن IP دستگاه کاربر به لیست مجاز (اگر هنوز اضافه نشده)
          if (_deviceIp != null && !allowedIps.contains(_deviceIp)) {
            allowedIps.add(_deviceIp!);
          }
          
          // ایجاد یک Set از دستگاه‌های مجاز بر اساس MAC و IP
          // این برای بررسی سریع‌تر استفاده می‌شود
          final allowedDevices = <String>{};
          for (var mac in allowedMacs) {
            allowedDevices.add('mac:$mac');
          }
          for (var ip in allowedIps) {
            allowedDevices.add('ip:$ip');
          }
          
          // بررسی همه دستگاه‌های متصل فعلی
          // هر دستگاهی که MAC یا IP آن در لیست اولیه نیست، باید مسدود شود
          // این شامل دستگاه‌هایی می‌شود که:
          // 1. برای اولین بار بعد از فعال شدن قفل وصل شده‌اند
          // 2. قبلاً وصل شده بودند اما disconnect شده‌اند و دوباره وصل شده‌اند
          bool anyDeviceBanned = false;
          for (var client in clientsList.toList()) {
            final clientMac = client.macAddress?.toUpperCase();
            final clientIp = client.ipAddress;
            
            // بررسی اینکه آیا دستگاه مجاز است یا نه
            bool isAllowed = false;
            
            // اگر IP دستگاه کاربر است، همیشه مجاز است
            if (clientIp != null && clientIp == _deviceIp) {
              isAllowed = true;
            }
            
            // بررسی اینکه آیا دستگاه در لیست مجاز است
            if (!isAllowed && clientIp != null) {
              // بررسی MAC
              if (clientMac != null && clientMac.isNotEmpty) {
                if (allowedDevices.contains('mac:$clientMac')) {
                  isAllowed = true;
                }
              }
              
              // بررسی IP
              if (!isAllowed && clientIp.isNotEmpty) {
                if (allowedDevices.contains('ip:$clientIp')) {
                  isAllowed = true;
                }
              }
            }
            
            // اگر مجاز نیست، مسدود کن و از لیست حذف کن
            // این شامل دستگاه‌هایی می‌شود که:
            // - برای اولین بار بعد از فعال شدن قفل وصل شده‌اند
            // - قبلاً وصل شده بودند اما disconnect شده‌اند و دوباره وصل شده‌اند
            if (!isAllowed) {
              bool wasBanned = false;
              try {
                // مسدود کردن دستگاه جدید یا دستگاه که دوباره وصل شده یا non-static
                if (client.ipAddress != null) {
                  final banResult = await _serviceManager.service?.banClient(
                    client.ipAddress!,
                    macAddress: client.macAddress,
                    comment: 'Auto-banned: New connection while locked',
                  );
                  wasBanned = banResult == true;
                  if (wasBanned) {
                    anyDeviceBanned = true;
                  }
                }
              } catch (e) {
                // ignore errors
              }
              // حذف از لیست متصل (حتی اگر banClient خطا داد)
              clientsList.remove(client);
            }
          }
          
          // اگر دستگاهی مسدود شد، لیست banned clients را به‌روزرسانی کن (یک بار)
          if (anyDeviceBanned) {
            try {
              await loadBannedClients();
            } catch (e) {
              // ignore errors
            }
          }
        } catch (e) {
          // ignore errors
        }
      }

      // حذف دستگاه‌های مسدود شده از لیست متصل
      // استفاده از Device Fingerprint برای شناسایی دستگاه‌های مسدود شده
      try {
        // بررسی و مسدود کردن خودکار دستگاه‌هایی که Device Fingerprint آن‌ها مسدود شده است
        try {
          await _serviceManager.service?.checkAndBanBannedDevices();
        } catch (e) {
          // ignore errors in auto-ban check
        }

        // دریافت لیست دستگاه‌های مسدود شده (شامل auto-banned)
        final bannedClients = await _serviceManager.getBannedClients();
        final bannedIps = bannedClients
            .map((b) => b['address']?.toString())
            .where((ip) => ip != null && ip.isNotEmpty)
            .toSet();

        final bannedMacs = <String>{};
        for (var banned in bannedClients) {
          final mac = banned['mac_address']?.toString();
          if (mac != null && mac.isNotEmpty) {
            bannedMacs.add(mac.toUpperCase());
          }
        }

        // حذف دستگاه‌های مسدود شده از لیست متصل
        clientsList.removeWhere((client) {
          // بررسی IP
          if (client.ipAddress != null &&
              bannedIps.contains(client.ipAddress)) {
            return true;
          }
          // بررسی MAC
          if (client.macAddress != null) {
            final clientMacUpper = client.macAddress!.toUpperCase();
            if (bannedMacs.contains(clientMacUpper)) {
              return true;
            }
          }
          return false;
        });
      } catch (e) {
        // اگر خطا در دریافت لیست مسدود شده‌ها رخ داد، ادامه بده
      }

      // مرتب‌سازی: دستگاه کاربر در صدر لیست
      // اگر IP دستگاه کاربر هنوز تشخیص داده نشده، دوباره تلاش کن
      if (_deviceIp == null) {
        try {
          await loadDeviceIp(forceRefresh: true);
        } catch (e) {
          // ignore
        }
      }

      clientsList.sort((a, b) {
        if (_deviceIp != null) {
          final aIsDevice = a.ipAddress == _deviceIp;
          final bIsDevice = b.ipAddress == _deviceIp;
          if (aIsDevice && !bIsDevice) return -1;
          if (!aIsDevice && bIsDevice) return 1;
        }
        return 0;
      });

      _clients = clientsList;
      _isDataComplete = dataComplete;
      _isLoading = false;
      _errorMessage = null;
      
      // به‌روزرسانی cache وضعیت Static برای دستگاه‌های متصل
      // این کار به صورت غیرهمزمان انجام می‌شود تا UI را block نکند
      _updateStaticStatusCache(clientsList);
      
      notifyListeners();
    } catch (e) {
      _errorMessage = 'خطا در دریافت لیست کاربران: $e';
      _isLoading = false;
      _isDataComplete = false;
      notifyListeners();
    }
  }

  /// بارگذاری لیست دستگاه‌های مسدود شده
  Future<void> loadBannedClients() async {
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final bannedList = await _serviceManager.getBannedClients();
      _bannedClients = bannedList;
      notifyListeners();
    } catch (e) {
      // ignore
    }
  }

  /// به‌روزرسانی کامل داده‌ها (برای refresh)
  Future<void> refresh() async {
    _isRefreshing = true;
    notifyListeners();

    try {
      await loadDeviceIp();
      await loadRouterInfo();
      await loadClients(showLoading: false);
      await loadBannedClients();
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// مسدود کردن کلاینت با استفاده از Device Fingerprint
  /// این تابع Device Fingerprint را محاسبه و ذخیره می‌کند
  Future<bool> banClient(String ipAddress, {String? macAddress, String? hostname, String? ssid}) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.service?.banClientWithFingerprint(
        ipAddress,
        macAddress: macAddress,
        hostname: hostname,
        ssid: ssid,
      );

      if (success == true) {
        // بررسی و مسدود کردن خودکار دستگاه‌های دیگر که Device Fingerprint آن‌ها مسدود شده است
        try {
          await _serviceManager.service?.checkAndBanBannedDevices();
        } catch (e) {
          // ignore errors in auto-ban
        }
        
        // به‌روزرسانی فوری state
        await refresh();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در مسدود کردن کلاینت: $e';
      notifyListeners();
      return false;
    }
  }

  /// رفع مسدودیت کلاینت با استفاده از Device Fingerprint
  Future<bool> unbanClient(String ipAddress, {String? macAddress, String? hostname, String? ssid}) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.service?.unbanClientWithFingerprint(
        ipAddress,
        macAddress: macAddress,
        hostname: hostname,
        ssid: ssid,
      );

      if (success == true) {
        // به‌روزرسانی فوری state
        // ابتدا لیست banned clients را به‌روزرسانی کن تا دستگاه از لیست حذف شود
        await loadBannedClients();
        // سپس لیست متصل را به‌روزرسانی کن
        await loadClients(showLoading: false);
        // اطمینان از به‌روزرسانی UI
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در رفع مسدودیت کلاینت: $e';
      notifyListeners();
      return false;
    }
  }

  /// تنظیم سرعت کلاینت و به‌روزرسانی state
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
        // به‌روزرسانی فوری state
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

  /// پاک کردن state (برای logout)
  void clear() {
    _cancelAutoBanTimer(); // توقف Timer
    _isLoading = false;
    _isDataComplete = false;
    _clients = [];
    _bannedClients = [];
    _errorMessage = null;
    _deviceIp = null;
    _isRefreshing = false;
    _routerInfo = null;
    _isNewConnectionsLocked = false;
    _deviceStaticStatus.clear(); // پاک کردن cache وضعیت Static
    _deviceFilterStatus.clear(); // پاک کردن cache وضعیت فیلترینگ
    notifyListeners();
  }

  /// مقداردهی اولیه (برای بعد از login)
  Future<void> initialize() async {
    await loadDeviceIp();
    await loadRouterInfo();
    await loadClients();
    await loadBannedClients();
    // بررسی وضعیت قفل
    try {
      _isNewConnectionsLocked = await _serviceManager.isNewConnectionsLocked();
      _updateAutoBanTimer(); // شروع Timer اگر قفل فعال است
      notifyListeners();
    } catch (e) {
      // ignore
    }
  }

  /// قفل کردن اتصال دستگاه‌های جدید
  Future<bool> lockNewConnections() async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.lockNewConnections();
      if (success) {
        _isNewConnectionsLocked = true;
        _updateAutoBanTimer(); // شروع Timer برای بررسی دوره‌ای
        await refresh();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در قفل کردن اتصال جدید: $e';
      notifyListeners();
      return false;
    }
  }

  /// رفع قفل اتصال دستگاه‌های جدید
  Future<bool> unlockNewConnections() async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.unlockNewConnections();
      if (success) {
        _isNewConnectionsLocked = false;
        _updateAutoBanTimer(); // توقف Timer
        // به‌روزرسانی لیست banned clients برای حذف دستگاه‌های auto-banned که رفع مسدودیت شدند
        await loadBannedClients();
        await refresh();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در رفع قفل اتصال جدید: $e';
      notifyListeners();
      return false;
    }
  }

  /// به‌روزرسانی Timer برای بررسی دوره‌ای دستگاه‌های جدید
  /// Timer فقط زمانی فعال است که قفل اتصال جدید فعال باشد
  void _updateAutoBanTimer() {
    // توقف Timer قبلی (اگر وجود دارد)
    _autoBanCheckTimer?.cancel();
    _autoBanCheckTimer = null;

    // اگر قفل فعال است و اتصال برقرار است، Timer را شروع کن
    if (_isNewConnectionsLocked && _serviceManager.isConnected) {
      _autoBanCheckTimer = Timer.periodic(_autoBanCheckInterval, (timer) async {
        // بررسی اینکه آیا هنوز قفل فعال است و اتصال برقرار است
        if (!_isNewConnectionsLocked || !_serviceManager.isConnected) {
          timer.cancel();
          _autoBanCheckTimer = null;
          return;
        }

        // بررسی و مسدود کردن دستگاه‌های جدید (بدون نمایش loading)
        try {
          // بررسی و مسدود کردن دستگاه‌های جدید
          await loadClients(showLoading: false);
          // به‌روزرسانی لیست banned clients برای نمایش دستگاه‌های auto-banned
          await loadBannedClients();
          // اطمینان از به‌روزرسانی UI
          notifyListeners();
        } catch (e) {
          // ignore errors - Timer ادامه می‌دهد
        }
      });
    }
  }

  /// پاک کردن Timer (برای cleanup)
  void _cancelAutoBanTimer() {
    _autoBanCheckTimer?.cancel();
    _autoBanCheckTimer = null;
  }

  /// فعال‌سازی فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  Future<Map<String, dynamic>> enableSocialMediaFilter(
    String deviceIp, {
    String? deviceMac,
    String? deviceName,
    List<String>? platforms,
  }) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return {'success': false, 'error': _errorMessage};
    }

    try {
      final result = await _serviceManager.service?.enableSocialMediaFilter(
        deviceIp,
        deviceMac: deviceMac,
        deviceName: deviceName,
        platforms: platforms,
      );

      if (result != null && result['success'] == true) {
        await refresh();
        return result;
      } else {
        _errorMessage = result?['errors']?.join(', ') ?? 'خطا در فعال‌سازی فیلتر';
        notifyListeners();
        return result ?? {'success': false, 'error': 'خطای نامشخص'};
      }
    } catch (e) {
      _errorMessage = 'خطا در فعال‌سازی فیلتر شبکه‌های اجتماعی: $e';
      notifyListeners();
      return {'success': false, 'error': _errorMessage};
    }
  }

  /// غیرفعال‌سازی فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  Future<bool> disableSocialMediaFilter(String deviceIp) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.service?.disableSocialMediaFilter(deviceIp);
      if (success == true) {
        await refresh();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در غیرفعال‌سازی فیلتر: $e';
      notifyListeners();
      return false;
    }
  }

  /// بررسی وضعیت فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  /// با استفاده از cache برای بهبود عملکرد و حفظ حالت
  Future<Map<String, dynamic>> getSocialMediaFilterStatus(String deviceIp, {bool forceRefresh = false}) async {
    if (!_serviceManager.isConnected) {
      // اگر cache موجود است، از آن استفاده کن
      if (_deviceFilterStatus.containsKey(deviceIp)) {
        final cached = _deviceFilterStatus[deviceIp]!;
        return {
          'is_active': cached.values.any((v) => v == true),
          'platforms': Map<String, dynamic>.from(cached),
        };
      }
      return {'is_active': false, 'error': 'اتصال برقرار نشده است.'};
    }

    // اگر forceRefresh نیست و cache موجود است، از cache استفاده کن
    if (!forceRefresh && _deviceFilterStatus.containsKey(deviceIp)) {
      final cached = _deviceFilterStatus[deviceIp]!;
      print('[Filter Status] استفاده از cache برای $deviceIp: $cached');
      // در پس‌زمینه به‌روزرسانی کن (بدون blocking کردن UI)
      _refreshFilterStatusInBackground(deviceIp);
      return {
        'is_active': cached.values.any((v) => v == true),
        'platforms': Map<String, dynamic>.from(cached),
      };
    }

    try {
      final status = await _serviceManager.service?.getSocialMediaFilterStatus(deviceIp);
      final platforms = status?['platforms'] as Map<String, dynamic>? ?? {};
      
      // به‌روزرسانی cache
      final platformStatus = <String, bool>{
        'telegram': platforms['telegram'] == true,
        'facebook': platforms['facebook'] == true,
        'tiktok': platforms['tiktok'] == true,
        'whatsapp': platforms['whatsapp'] == true,
        'youtube': platforms['youtube'] == true,
        'instagram': platforms['instagram'] == true,
      };
      _deviceFilterStatus[deviceIp] = platformStatus;
      print('[Filter Status] به‌روزرسانی cache برای $deviceIp: $platformStatus');
      
      return status ?? {'is_active': false, 'platforms': {}};
    } catch (e) {
      // در صورت خطا، اگر cache موجود است، از آن استفاده کن
      if (_deviceFilterStatus.containsKey(deviceIp)) {
        final cached = _deviceFilterStatus[deviceIp]!;
        print('[Filter Status] خطا در دریافت وضعیت، استفاده از cache: $e');
        return {
          'is_active': cached.values.any((v) => v == true),
          'platforms': Map<String, dynamic>.from(cached),
          'error': e.toString(),
        };
      }
      return {'is_active': false, 'error': e.toString(), 'platforms': {}};
    }
  }

  /// به‌روزرسانی وضعیت فیلتر در پس‌زمینه
  Future<void> _refreshFilterStatusInBackground(String deviceIp) async {
    try {
      final status = await _serviceManager.service?.getSocialMediaFilterStatus(deviceIp);
      final platforms = status?['platforms'] as Map<String, dynamic>? ?? {};
      
      final platformStatus = <String, bool>{
        'telegram': platforms['telegram'] == true,
        'facebook': platforms['facebook'] == true,
        'tiktok': platforms['tiktok'] == true,
        'whatsapp': platforms['whatsapp'] == true,
        'youtube': platforms['youtube'] == true,
        'instagram': platforms['instagram'] == true,
      };
      
      // بررسی تغییرات با مقایسه عمیق
      final cached = _deviceFilterStatus[deviceIp];
      bool hasChanges = false;
      if (cached == null) {
        hasChanges = true;
      } else {
        for (final key in platformStatus.keys) {
          if (cached[key] != platformStatus[key]) {
            hasChanges = true;
            break;
          }
        }
      }
      
      if (hasChanges) {
        _deviceFilterStatus[deviceIp] = platformStatus;
        print('[Filter Status] پس‌زمینه به‌روزرسانی cache برای $deviceIp: $platformStatus');
        notifyListeners(); // اطلاع دادن به listeners که وضعیت تغییر کرده است
      }
    } catch (e) {
      // ignore errors in background refresh
      print('[Filter Status] خطا در به‌روزرسانی پس‌زمینه: $e');
    }
  }

  /// فیلتر/رفع فیلتر یک پلتفرم خاص برای یک دستگاه
  Future<Map<String, dynamic>> togglePlatformFilter(
    String deviceIp,
    String platform, {
    String? deviceMac,
    String? deviceName,
    bool enable = true,
  }) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return {'success': false, 'error': _errorMessage};
    }

    try {
      final result = await _serviceManager.service?.togglePlatformFilter(
        deviceIp,
        platform,
        deviceMac: deviceMac,
        deviceName: deviceName,
        enable: enable,
      );

      if (result != null && result['success'] == true) {
        // به‌روزرسانی cache فوری
        if (!_deviceFilterStatus.containsKey(deviceIp)) {
          _deviceFilterStatus[deviceIp] = {
            'telegram': false,
            'facebook': false,
            'tiktok': false,
            'whatsapp': false,
            'youtube': false,
            'instagram': false,
          };
        }
        _deviceFilterStatus[deviceIp]![platform.toLowerCase()] = enable;
        print('[Filter Status] به‌روزرسانی cache بعد از toggle برای $deviceIp: ${_deviceFilterStatus[deviceIp]}');
        
        // به‌روزرسانی کامل از سرور (برای اطمینان)
        Future.delayed(const Duration(milliseconds: 500), () {
          _refreshFilterStatusInBackground(deviceIp);
        });
        
        await refresh();
        notifyListeners(); // اطلاع دادن به listeners
        return result;
      } else {
        _errorMessage = result?['error']?.toString() ?? 'خطا در تغییر وضعیت فیلتر';
        notifyListeners();
        return result ?? {'success': false, 'error': 'خطای نامشخص'};
      }
    } catch (e) {
      _errorMessage = 'خطا در تغییر وضعیت فیلتر: $e';
      notifyListeners();
      return {'success': false, 'error': _errorMessage};
    }
  }

  /// بررسی اینکه آیا دستگاه Static است یا نه
  Future<bool> isDeviceStatic(String? ipAddress, String? macAddress, {String? hostname}) async {
    print('[STATIC] ClientsProvider.isDeviceStatic: شروع');
    print('[STATIC] IP: $ipAddress, MAC: $macAddress, hostname: $hostname');
    print('[STATIC] isConnected: ${_serviceManager.isConnected}');
    
    // ابتدا از cache بررسی کن
    String? cacheKey;
    if (ipAddress != null && ipAddress.isNotEmpty) {
      cacheKey = 'ip:$ipAddress';
      if (_deviceStaticStatus.containsKey(cacheKey)) {
        final cached = _deviceStaticStatus[cacheKey]!;
        print('[STATIC] ClientsProvider.isDeviceStatic: از cache: $cached (key: $cacheKey)');
        return cached;
      }
    }
    if (macAddress != null && macAddress.isNotEmpty) {
      cacheKey = 'mac:${macAddress.toUpperCase()}';
      if (_deviceStaticStatus.containsKey(cacheKey)) {
        final cached = _deviceStaticStatus[cacheKey]!;
        print('[STATIC] ClientsProvider.isDeviceStatic: از cache: $cached (key: $cacheKey)');
        return cached;
      }
    }
    // بررسی cache با hostname (برای حالتی که MAC تغییر کرده)
    if (hostname != null && hostname.isNotEmpty) {
      cacheKey = 'hostname:${hostname.toLowerCase().trim()}';
      if (_deviceStaticStatus.containsKey(cacheKey)) {
        final cached = _deviceStaticStatus[cacheKey]!;
        print('[STATIC] ClientsProvider.isDeviceStatic: از cache: $cached (key: $cacheKey)');
        return cached;
      }
    }
    
    if (!_serviceManager.isConnected) {
      print('[STATIC] ClientsProvider.isDeviceStatic: اتصال برقرار نیست');
      return false;
    }

    try {
      print('[STATIC] ClientsProvider.isDeviceStatic: فراخوانی serviceManager.isDeviceStatic');
      final result = await _serviceManager.isDeviceStatic(ipAddress, macAddress, hostname: hostname);
      print('[STATIC] ClientsProvider.isDeviceStatic: نتیجه از سرور: $result');
      
      // ذخیره در cache
      if (ipAddress != null && ipAddress.isNotEmpty) {
        _deviceStaticStatus['ip:$ipAddress'] = result;
        print('[STATIC] ClientsProvider.isDeviceStatic: ذخیره در cache: ip:$ipAddress = $result');
      }
      if (macAddress != null && macAddress.isNotEmpty) {
        _deviceStaticStatus['mac:${macAddress.toUpperCase()}'] = result;
        print('[STATIC] ClientsProvider.isDeviceStatic: ذخیره در cache: mac:${macAddress.toUpperCase()} = $result');
      }
      if (hostname != null && hostname.isNotEmpty) {
        _deviceStaticStatus['hostname:${hostname.toLowerCase().trim()}'] = result;
        print('[STATIC] ClientsProvider.isDeviceStatic: ذخیره در cache: hostname:${hostname.toLowerCase().trim()} = $result');
      }
      
      return result;
    } catch (e) {
      print('[STATIC] ClientsProvider.isDeviceStatic: خطا: $e');
      print('[STATIC] Stack trace: ${StackTrace.current}');
      return false;
    }
  }

  /// تبدیل دستگاه به Static یا غیر Static
  Future<bool> setDeviceStaticStatus(
    String ipAddress,
    String? macAddress, {
    String? hostname,
    bool isStatic = true,
  }) async {
    print('[STATIC] ClientsProvider.setDeviceStaticStatus: شروع');
    print('[STATIC] IP: $ipAddress, MAC: $macAddress, hostname: $hostname, isStatic: $isStatic');
    print('[STATIC] isConnected: ${_serviceManager.isConnected}');
    
    if (!_serviceManager.isConnected) {
      print('[STATIC] ClientsProvider.setDeviceStaticStatus: اتصال برقرار نیست');
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      print('[STATIC] ClientsProvider.setDeviceStaticStatus: فراخوانی serviceManager.setDeviceStaticStatus');
      final success = await _serviceManager.setDeviceStaticStatus(
        ipAddress,
        macAddress,
        hostname: hostname,
        isStatic: isStatic,
      );

      print('[STATIC] ClientsProvider.setDeviceStaticStatus: نتیجه: $success');

      if (success) {
        print('[STATIC] ClientsProvider.setDeviceStaticStatus: موفق بود، به‌روزرسانی cache');
        
        // به‌روزرسانی cache
        _deviceStaticStatus['ip:$ipAddress'] = isStatic;
        print('[STATIC] ClientsProvider.setDeviceStaticStatus: به‌روزرسانی cache: ip:$ipAddress = $isStatic');
        if (macAddress != null && macAddress.isNotEmpty) {
          _deviceStaticStatus['mac:${macAddress.toUpperCase()}'] = isStatic;
          print('[STATIC] ClientsProvider.setDeviceStaticStatus: به‌روزرسانی cache: mac:${macAddress.toUpperCase()} = $isStatic');
        }
        
        notifyListeners();
        
        print('[STATIC] ClientsProvider.setDeviceStaticStatus: refresh می‌کنم');
        await refresh();
        return true;
      } else {
        print('[STATIC] ClientsProvider.setDeviceStaticStatus: ناموفق بود');
      }
      return false;
    } catch (e) {
      print('[STATIC] ClientsProvider.setDeviceStaticStatus: خطا: $e');
      print('[STATIC] Stack trace: ${StackTrace.current}');
      _errorMessage = 'خطا در تغییر وضعیت Static: $e';
      notifyListeners();
      return false;
    }
  }

  /// به‌روزرسانی cache وضعیت Static برای لیست دستگاه‌ها
  /// این متد به صورت غیرهمزمان وضعیت Static را از سرور می‌گیرد و در cache ذخیره می‌کند
  Future<void> _updateStaticStatusCache(List<ClientInfo> clients) async {
    if (!_serviceManager.isConnected || clients.isEmpty) {
      return;
    }

    // فقط برای دستگاه‌هایی که IP دارند
    for (var client in clients) {
      if (client.ipAddress != null && client.ipAddress!.isNotEmpty) {
        final ip = client.ipAddress!;
        final mac = client.macAddress;
        
        // اگر در cache نیست، از سرور بگیر
        final cacheKey = 'ip:$ip';
        if (!_deviceStaticStatus.containsKey(cacheKey)) {
          try {
            final isStatic = await _serviceManager.isDeviceStatic(ip, mac);
            _deviceStaticStatus[cacheKey] = isStatic;
            if (mac != null && mac.isNotEmpty) {
              _deviceStaticStatus['mac:${mac.toUpperCase()}'] = isStatic;
            }
            print('[STATIC] ClientsProvider._updateStaticStatusCache: به‌روزرسانی cache برای $ip = $isStatic');
          } catch (e) {
            // ignore errors - cache optional است
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _cancelAutoBanTimer();
    super.dispose();
  }

}
