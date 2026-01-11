import 'package:flutter/material.dart';
import '../services/mikrotik_service_manager.dart';
import '../services/settings_service.dart';
import '../providers/clients_provider.dart';
import 'package:provider/provider.dart';

/// صفحه تنظیمات برنامه
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  bool _isDarkMode = false;
  String _selectedLanguage = 'فارسی';

  static const Color _primaryColor = Color(0xFF428B7C);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تنظیمات'),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: Colors.grey.shade50,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // بخش تنظیمات عمومی
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  // تغییر زبان
                  ListTile(
                    leading: Icon(
                      Icons.language,
                      color: _primaryColor,
                    ),
                    title: const Text(
                      'زبان برنامه',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      _selectedLanguage,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                    trailing: Switch(
                      value: _selectedLanguage == 'انگلیسی',
                      onChanged: (value) {
                        setState(() {
                          _selectedLanguage = value ? 'انگلیسی' : 'فارسی';
                        });
                        // نمایشی - فعلاً فقط نمایش می‌دهد
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'زبان به $_selectedLanguage تغییر یافت (نمایشی)',
                            ),
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      activeColor: _primaryColor,
                    ),
                  ),
                  const Divider(height: 1),
                  // تغییر تم
                  ListTile(
                    leading: Icon(
                      _isDarkMode ? Icons.dark_mode : Icons.light_mode,
                      color: _primaryColor,
                    ),
                    title: const Text(
                      'حالت تم',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      _isDarkMode ? 'تاریک' : 'روشن',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                    trailing: Switch(
                      value: _isDarkMode,
                      onChanged: (value) {
                        setState(() {
                          _isDarkMode = value;
                        });
                        // نمایشی - فعلاً فقط نمایش می‌دهد
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'تم به ${value ? "تاریک" : "روشن"} تغییر یافت (نمایشی)',
                            ),
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      activeColor: _primaryColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // دکمه خروج
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.logout,
                  color: Colors.red,
                ),
                title: const Text(
                  'خروج از حساب',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.red,
                  ),
                ),
                subtitle: const Text(
                  'خروج از حساب کاربری',
                  style: TextStyle(
                    fontSize: 14,
                  ),
                ),
                onTap: _handleLogout,
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.red,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('خروج از حساب'),
        content: const Text('آیا مطمئن هستید که می‌خواهید از حساب کاربری خارج شوید؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('خروج'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      provider.clear();
      _serviceManager.disconnect();
      
      // پاک کردن زمان لاگین
      final settingsService = SettingsService();
      await settingsService.clearLoginTimestamp();
      
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/');
      }
    }
  }
}

