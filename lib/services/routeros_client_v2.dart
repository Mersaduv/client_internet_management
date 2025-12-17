import 'package:router_os_client/router_os_client.dart';

/// کلاینت برای اتصال به MikroTik RouterOS API v6
/// استفاده از پکیج router_os_client
class RouterOSClientV2 {
  final String address;
  final String user;
  final String password;
  final bool useSsl;
  final int port;

  RouterOSClient? _client;
  bool _isConnected = false;
  bool _isAuthenticated = false;

  RouterOSClientV2({
    required this.address,
    required this.user,
    required this.password,
    this.useSsl = false,
    this.port = 8728,
  });

  /// اتصال و احراز هویت
  Future<bool> login() async {
    try {
      // ایجاد کلاینت
      _client = RouterOSClient(
        address: address,
        user: user,
        password: password,
        useSsl: useSsl,
        port: port,
      );

      // اتصال و احراز هویت
      final ok = await _client!.login();
      if (ok) {
        _isConnected = true;
        _isAuthenticated = true;
      }
      return ok;
    } catch (e) {
      _isConnected = false;
      _isAuthenticated = false;
      throw Exception('خطا در اتصال: $e');
    }
  }

  /// ارسال دستور و دریافت پاسخ
  Future<List<Map<String, String>>> talk(List<String> command) async {
    if (_client == null || !_isConnected || !_isAuthenticated) {
      throw Exception('اتصال برقرار نشده یا احراز هویت انجام نشده');
    }

    try {
      // اجرای دستور - پکیج router_os_client از List<String> پشتیبانی می‌کند
      final result = await _client!.talk(command);
      
      // تبدیل نتیجه به List<Map<String, String>>
      final List<Map<String, String>> convertedResult = [];
      
      for (var item in result) {
        final Map<String, String> convertedItem = {};
        item.forEach((key, value) {
          convertedItem[key.toString()] = value.toString();
        });
        convertedResult.add(convertedItem);
      }
      
      return convertedResult;
    } catch (e) {
      throw Exception('خطا در اجرای دستور: $e');
    }
  }

  /// بستن اتصال
  void close() {
    _client?.close();
    _client = null;
    _isConnected = false;
    _isAuthenticated = false;
  }

  bool get isConnected => _isConnected && _isAuthenticated;
}

