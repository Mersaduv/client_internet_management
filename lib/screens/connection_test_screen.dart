import 'package:flutter/material.dart';
import '../models/mikrotik_connection.dart';
import '../services/mikrotik_service.dart';

/// صفحه تست اتصال به MikroTik RouterOS
class ConnectionTestScreen extends StatefulWidget {
  const ConnectionTestScreen({super.key});

  @override
  State<ConnectionTestScreen> createState() => _ConnectionTestScreenState();
}

class _ConnectionTestScreenState extends State<ConnectionTestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController(text: '192.168.88.1');
  final _portController = TextEditingController(text: '8728');
  final _usernameController = TextEditingController(text: 'admin');
  final _passwordController = TextEditingController();
  
  bool _useSsl = false;
  bool _isConnecting = false;
  String? _connectionResult;
  bool? _isConnected;
  MikroTikService? _service;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _service?.disconnect();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionResult = null;
      _isConnected = null;
    });

    try {
      // بستن اتصال قبلی اگر وجود دارد
      _service?.disconnect();

      // ایجاد سرویس جدید
      _service = MikroTikService();

      // ایجاد اتصال
      final connection = MikroTikConnection(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 8728,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        useSsl: _useSsl,
      );

      final success = await _service!.connect(connection);

      setState(() {
        _isConnecting = false;
        _isConnected = success;
        if (success) {
          _connectionResult = 'اتصال با موفقیت برقرار شد! ✅';
        } else {
          _connectionResult = 'اتصال برقرار نشد. لطفاً اطلاعات را بررسی کنید. ❌';
        }
      });
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _isConnected = false;
        _connectionResult = 'خطا: $e';
      });
    }
  }

  Future<void> _testGetClients() async {
    if (_service == null || !_service!.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ابتدا اتصال را برقرار کنید')),
      );
      return;
    }

    try {
      setState(() {
        _isConnecting = true;
      });

      final result = await _service!.getAllClients();
      
      setState(() {
        _isConnecting = false;
      });

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('نتیجه تست'),
            content: Text(
              'تعداد کلاینت‌ها: ${result['total_count']}\n'
              'Hotspot: ${result['by_type']['hotspot']}\n'
              'Wireless: ${result['by_type']['wireless']}\n'
              'DHCP: ${result['by_type']['dhcp']}\n'
              'PPP: ${result['by_type']['ppp']}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('بستن'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطا: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تست اتصال MikroTik'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // فیلد Host/IP
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'آدرس IP یا Hostname',
                  hintText: '192.168.88.1',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.router),
                ),
                keyboardType: TextInputType.text,
                textDirection: TextDirection.ltr,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'لطفاً آدرس IP را وارد کنید';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // فیلد Port
              TextFormField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: 'پورت',
                  hintText: '8728',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.numbers),
                ),
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'لطفاً پورت را وارد کنید';
                  }
                  final port = int.tryParse(value.trim());
                  if (port == null || port < 1 || port > 65535) {
                    return 'پورت باید عددی بین 1 تا 65535 باشد';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // فیلد Username
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'نام کاربری',
                  hintText: 'admin',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                textDirection: TextDirection.ltr,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'لطفاً نام کاربری را وارد کنید';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // فیلد Password
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'رمز عبور',
                  hintText: 'رمز عبور را وارد کنید',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
                textDirection: TextDirection.ltr,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'لطفاً رمز عبور را وارد کنید';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Checkbox SSL
              CheckboxListTile(
                title: const Text('استفاده از SSL (پورت 8729)'),
                subtitle: const Text('برای اتصال امن از SSL استفاده کنید'),
                value: _useSsl,
                onChanged: (value) {
                  setState(() {
                    _useSsl = value ?? false;
                    if (_useSsl && _portController.text == '8728') {
                      _portController.text = '8729';
                    } else if (!_useSsl && _portController.text == '8729') {
                      _portController.text = '8728';
                    }
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 24),

              // دکمه تست اتصال
              ElevatedButton.icon(
                onPressed: _isConnecting ? null : _testConnection,
                icon: _isConnecting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(_isConnecting ? 'در حال اتصال...' : 'تست اتصال'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),

              // دکمه تست دریافت کلاینت‌ها (فقط اگر متصل باشد)
              if (_isConnected == true)
                ElevatedButton.icon(
                  onPressed: _isConnecting ? null : _testGetClients,
                  icon: _isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.people),
                  label: Text(_isConnecting
                      ? 'در حال دریافت...'
                      : 'تست دریافت کلاینت‌ها'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              if (_isConnected == true) const SizedBox(height: 16),

              // نمایش نتیجه
              if (_connectionResult != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _isConnected == true
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    border: Border.all(
                      color: _isConnected == true
                          ? Colors.green
                          : Colors.red,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isConnected == true
                            ? Icons.check_circle
                            : Icons.error,
                        color: _isConnected == true
                            ? Colors.green
                            : Colors.red,
                        size: 32,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          _connectionResult!,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _isConnected == true
                                ? Colors.green.shade900
                                : Colors.red.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

