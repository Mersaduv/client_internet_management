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
          // همچنین دستگاه‌هایی که non-static هستند باید مسدود شوند (حتی اگر در لیست مجاز هستند)
          // این شامل دستگاه‌هایی می‌شود که:
          // 1. برای اولین بار بعد از فعال شدن قفل وصل شده‌اند
          // 2. قبلاً وصل شده بودند اما disconnect شده‌اند و دوباره وصل شده‌اند
          // 3. دستگاه‌هایی که non-static هستند (باید همیشه مسدود شوند)
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
            
            // اگر دستگاه کاربر نیست، بررسی کن که آیا static است یا نه
            // دستگاه‌های non-static باید مسدود شوند (حتی اگر در لیست مجاز هستند)
            if (!isAllowed && clientIp != null) {
              bool isStatic = false;
              try {
                isStatic = await _serviceManager.isDeviceStatic(
                  clientIp,
                  clientMac,
                );
              } catch (e) {
                // اگر نتوانستیم بررسی کنیم، فرض می‌کنیم non-static است
                isStatic = false;
              }
              
              // اگر دستگاه static است، بررسی کن که آیا در لیست مجاز است یا نه
              // اگر static نیست، مجاز نیست (باید مسدود شود)
              if (isStatic) {
                // دستگاه static است - بررسی کن که آیا در لیست مجاز است
                if (clientMac != null && clientMac.isNotEmpty) {
                  if (allowedDevices.contains('mac:$clientMac')) {
                    isAllowed = true;
                  }
                }
                
                if (!isAllowed && clientIp.isNotEmpty) {
                  if (allowedDevices.contains('ip:$clientIp')) {
                    isAllowed = true;
                  }
                }
              }
              // اگر non-static است، isAllowed = false (باید مسدود شود)
            }
            
            // اگر مجاز نیست یا non-static است، مسدود کن و از لیست حذف کن
            // این شامل دستگاه‌هایی می‌شود که:
            // - برای اولین بار بعد از فعال شدن قفل وصل شده‌اند
            // - قبلاً وصل شده بودند اما disconnect شده‌اند و دوباره وصل شده‌اند
            // - دستگاه‌هایی که non-static هستند (باید همیشه مسدود شوند)
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

  /// بررسی اینکه آیا دستگاه static است یا نه
  Future<bool> isDeviceStatic(String? ipAddress, String? macAddress) async {
    if (!_serviceManager.isConnected) {
      return false;
    }

    try {
      return await _serviceManager.isDeviceStatic(ipAddress, macAddress);
    } catch (e) {
      return false;
    }
  }

  /// تبدیل دستگاه به static یا non-static و به‌روزرسانی state
  Future<bool> setDeviceStaticStatus(
    String ipAddress,
    String? macAddress, {
    String? hostname,
    bool isStatic = true,
  }) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.setDeviceStaticStatus(
        ipAddress,
        macAddress,
        hostname: hostname,
        isStatic: isStatic,
      );

      if (success) {
        // به‌روزرسانی فوری state
        await refresh();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'خطا در تبدیل دستگاه: $e';
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

  @override
  void dispose() {
    _cancelAutoBanTimer();
    super.dispose();
  }

}
