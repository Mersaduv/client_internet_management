import 'package:shared_preferences/shared_preferences.dart';

/// سرویس برای مدیریت تنظیمات اتصال MikroTik
class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  static const String _keyHost = 'mikrotik_host';
  static const String _keyPort = 'mikrotik_port';
  static const String _keyUseSsl = 'mikrotik_use_ssl';
  static const String _keyServiceUrl = 'internet_service_url';

  // مقادیر پیش‌فرض
  static const String _defaultHost = '192.168.88.1';
  static const int _defaultPort = 8728;
  static const bool _defaultUseSsl = false;
  static const String _defaultServiceUrl = 'http://user.ariyabod.af/users/computer/DS_MyInternet.php';

  // Cache برای تنظیمات (برای جلوگیری از خطا در صورت مشکل shared_preferences)
  String? _cachedHost;
  int? _cachedPort;
  bool? _cachedUseSsl;
  String? _cachedServiceUrl;

  /// دریافت Host
  Future<String> getHost() async {
    if (_cachedHost != null) {
      return _cachedHost!;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedHost = prefs.getString(_keyHost) ?? _defaultHost;
      return _cachedHost!;
    } catch (e) {
      // در صورت خطا، از مقدار پیش‌فرض استفاده کن
      _cachedHost = _defaultHost;
      return _defaultHost;
    }
  }

  /// ذخیره Host
  Future<void> setHost(String host) async {
    _cachedHost = host;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyHost, host);
    } catch (e) {
      // اگر shared_preferences کار نکرد، فقط در حافظه نگه دار
    }
  }

  /// دریافت Port
  Future<int> getPort() async {
    if (_cachedPort != null) {
      return _cachedPort!;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedPort = prefs.getInt(_keyPort) ?? _defaultPort;
      return _cachedPort!;
    } catch (e) {
      // در صورت خطا، از مقدار پیش‌فرض استفاده کن
      _cachedPort = _defaultPort;
      return _defaultPort;
    }
  }

  /// ذخیره Port
  Future<void> setPort(int port) async {
    _cachedPort = port;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyPort, port);
    } catch (e) {
      // اگر shared_preferences کار نکرد، فقط در حافظه نگه دار
    }
  }

  /// دریافت UseSsl
  Future<bool> getUseSsl() async {
    if (_cachedUseSsl != null) {
      return _cachedUseSsl!;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedUseSsl = prefs.getBool(_keyUseSsl) ?? _defaultUseSsl;
      return _cachedUseSsl!;
    } catch (e) {
      // در صورت خطا، از مقدار پیش‌فرض استفاده کن
      _cachedUseSsl = _defaultUseSsl;
      return _defaultUseSsl;
    }
  }

  /// ذخیره UseSsl
  Future<void> setUseSsl(bool useSsl) async {
    _cachedUseSsl = useSsl;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseSsl, useSsl);
    } catch (e) {
      // اگر shared_preferences کار نکرد، فقط در حافظه نگه دار
    }
  }

  /// دریافت URL سرویس اینترنت
  Future<String> getServiceUrl() async {
    if (_cachedServiceUrl != null) {
      return _cachedServiceUrl!;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedServiceUrl = prefs.getString(_keyServiceUrl) ?? _defaultServiceUrl;
      return _cachedServiceUrl!;
    } catch (e) {
      _cachedServiceUrl = _defaultServiceUrl;
      return _defaultServiceUrl;
    }
  }

  /// ذخیره URL سرویس اینترنت
  Future<void> setServiceUrl(String url) async {
    _cachedServiceUrl = url;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyServiceUrl, url);
    } catch (e) {
      // اگر shared_preferences کار نکرد، فقط در حافظه نگه دار
    }
  }

  /// دریافت همه تنظیمات
  Future<Map<String, dynamic>> getAllSettings() async {
    return {
      'host': await getHost(),
      'port': await getPort(),
      'useSsl': await getUseSsl(),
      'serviceUrl': await getServiceUrl(),
    };
  }

  /// بازنشانی به تنظیمات پیش‌فرض
  Future<void> resetToDefaults() async {
    _cachedHost = null;
    _cachedPort = null;
    _cachedUseSsl = null;
    _cachedServiceUrl = null;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyHost);
      await prefs.remove(_keyPort);
      await prefs.remove(_keyUseSsl);
      await prefs.remove(_keyServiceUrl);
    } catch (e) {
      // اگر shared_preferences کار نکرد، فقط cache را پاک کن
    }
  }
}

