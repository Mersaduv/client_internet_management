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

  // Getters
  bool get isLoading => _isLoading;
  bool get isDataComplete => _isDataComplete;
  List<ClientInfo> get clients => _clients;
  List<Map<String, dynamic>> get bannedClients => _bannedClients;
  String? get errorMessage => _errorMessage;
  String? get deviceIp => _deviceIp;
  bool get isRefreshing => _isRefreshing;
  bool get isConnected => _serviceManager.isConnected;

  /// بارگذاری IP دستگاه
  Future<void> loadDeviceIp() async {
    // اگر IP قبلاً لود شده، دوباره لود نکن
    if (_deviceIp != null && !_isRefreshing) {
      return;
    }

    try {
      final ip = await _serviceManager.getDeviceIp().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (ip != null && _deviceIp != ip) {
        _deviceIp = ip;
        notifyListeners();
      }
    } catch (e) {
      // در صورت خطا، IP قبلی را حفظ کن
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

      // حذف دستگاه‌های مسدود شده از لیست متصل
      try {
        final bannedClients = await _serviceManager.getBannedClients();
        final bannedIps = bannedClients
            .map((b) => b['address']?.toString())
            .where((ip) => ip != null && ip.isNotEmpty)
            .toSet();

        final bannedMacs = bannedClients
            .map((b) => b['mac_address']?.toString())
            .where((mac) => mac != null && mac.isNotEmpty)
            .toSet();

        clientsList.removeWhere((client) {
          if (client.ipAddress != null &&
              bannedIps.contains(client.ipAddress)) {
            return true;
          }
          if (client.macAddress != null &&
              bannedMacs.contains(client.macAddress?.toUpperCase())) {
            return true;
          }
          return false;
        });
      } catch (e) {
        // اگر خطا در دریافت لیست مسدود شده‌ها رخ داد، ادامه بده
      }

      // مرتب‌سازی: دستگاه کاربر در صدر لیست
      if (_deviceIp == null) {
        try {
          final ip = await _serviceManager.getDeviceIp().timeout(
            const Duration(seconds: 2),
            onTimeout: () => null,
          );
          if (ip != null) {
            _deviceIp = ip;
          }
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
      await loadClients(showLoading: false);
      await loadBannedClients();
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// مسدود کردن کلاینت و به‌روزرسانی state
  Future<bool> banClient(String ipAddress, {String? macAddress}) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.service?.banClient(
        ipAddress,
        macAddress: macAddress,
      );

      if (success == true) {
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

  /// رفع مسدودیت کلاینت و به‌روزرسانی state
  Future<bool> unbanClient(String ipAddress, {String? macAddress}) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListeners();
      return false;
    }

    try {
      final success = await _serviceManager.service?.unbanClient(
        ipAddress,
        macAddress: macAddress,
      );

      if (success == true) {
        // به‌روزرسانی فوری state
        await refresh();
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
    _isLoading = false;
    _isDataComplete = false;
    _clients = [];
    _bannedClients = [];
    _errorMessage = null;
    _deviceIp = null;
    _isRefreshing = false;
    notifyListeners();
  }

  /// مقداردهی اولیه (برای بعد از login)
  Future<void> initialize() async {
    await loadDeviceIp();
    await loadClients();
    await loadBannedClients();
  }
}
