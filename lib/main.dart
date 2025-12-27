import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'screens/login_screen.dart';
import 'screens/connection_test_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/device_detail_screen.dart';
import 'screens/internet_service_screen.dart';
import 'services/mikrotik_service_manager.dart';
import 'services/settings_service.dart';
import 'models/client_info.dart';
import 'providers/clients_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ClientsProvider(),
      child: MaterialApp(
      title: 'مدیریت اینترنت',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF428B7C),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        primaryColor: const Color(0xFF428B7C),
        fontFamily: 'Vazir',
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontFamily: 'Vazir'),
          displayMedium: TextStyle(fontFamily: 'Vazir'),
          displaySmall: TextStyle(fontFamily: 'Vazir'),
          headlineLarge: TextStyle(fontFamily: 'Vazir'),
          headlineMedium: TextStyle(fontFamily: 'Vazir'),
          headlineSmall: TextStyle(fontFamily: 'Vazir'),
          titleLarge: TextStyle(fontFamily: 'Vazir'),
          titleMedium: TextStyle(fontFamily: 'Vazir'),
          titleSmall: TextStyle(fontFamily: 'Vazir'),
          bodyLarge: TextStyle(fontFamily: 'Vazir'),
          bodyMedium: TextStyle(fontFamily: 'Vazir'),
          bodySmall: TextStyle(fontFamily: 'Vazir'),
          labelLarge: TextStyle(fontFamily: 'Vazir'),
          labelMedium: TextStyle(fontFamily: 'Vazir'),
          labelSmall: TextStyle(fontFamily: 'Vazir'),
        ),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('fa', 'IR'), // فارسی
        Locale('en', 'US'), // انگلیسی
      ],
      locale: const Locale('fa', 'IR'),
      initialRoute: '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/home': (context) => const MainScaffold(),
        '/test': (context) => const ConnectionTestScreen(),
        '/device-detail': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
          return DeviceDetailScreen(
            device: args['device'] as ClientInfo,
            isCurrentDevice: args['isCurrentDevice'] as bool? ?? false,
            isBanned: args['isBanned'] as bool? ?? false,
          );
        },
      },
      ),
    );
  }
}

/// MainScaffold با bottom navigation ثابت برای همه صفحات
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    _checkLoginExpiration();
  }

  /// بررسی انقضای لاگین
  Future<void> _checkLoginExpiration() async {
    final isExpired = await _settingsService.isLoginExpired();
    if (isExpired && mounted) {
      // اگر لاگین منقضی شده باشد، به صفحه ورود هدایت کن
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      provider.clear();
      _serviceManager.disconnect();
      await _settingsService.clearLoginTimestamp();
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/');
      }
    }
  }

  void _onTabTapped(int index) {
    if (index == 3) {
      // خروج
      _handleLogout();
    } else if (index < 3) {
      setState(() {
        _currentIndex = index;
      });
    }
  }

  Future<void> _handleLogout() async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          HomePage(),
          InternetServiceScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          child: Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home,
                  label: 'خانه',
                  index: 0,
                  isActive: _currentIndex == 0,
                ),
                _buildNavItem(
                  icon: Icons.language_outlined,
                  activeIcon: Icons.language,
                  label: 'سرویس انترنت',
                  index: 1,
                  isActive: _currentIndex == 1,
                ),
                _buildNavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: 'تنظیمات',
                  index: 2,
                  isActive: _currentIndex == 2,
                ),
                _buildNavItem(
                  icon: Icons.logout_outlined,
                  activeIcon: Icons.logout,
                  label: 'خروج',
                  index: 3,
                  isActive: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required int index,
    required bool isActive,
  }) {
    return InkWell(
      onTap: () => _onTabTapped(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 60,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Icon(
          isActive ? activeIcon : icon,
          color: isActive
              ? const Color(0xFF428B7C)
              : Colors.grey.shade600,
          size: 28,
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  int _selectedTab = 0; // 0: متصل, 1: مسدود

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // مقداردهی اولیه Provider
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      provider.initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final connection = _serviceManager.currentConnection;
    final provider = Provider.of<ClientsProvider>(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('مدیریت اینترنت'),
        backgroundColor: const Color(0xFF428B7C),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: Colors.grey.shade50,
        child: Column(
          children: [
            // اطلاعات اتصال
            if (connection != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.router,
                          color: Color(0xFF428B7C),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                provider.routerInfo?['board-name'] != null && 
                                provider.routerInfo!['board-name'] != 'Unknown'
                                    ? provider.routerInfo!['board-name']!
                                    : '${connection.host}:${connection.port}',
                                style: const TextStyle(
                                  color: Colors.black87,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (provider.routerInfo?['board-name'] != null && 
                                  provider.routerInfo!['board-name'] != 'Unknown' &&
                                  provider.routerInfo?['platform'] != null &&
                                  provider.routerInfo!['platform'] != 'Unknown') ...[
                                const SizedBox(height: 2),
                                Text(
                                  provider.routerInfo!['platform']!,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (connection.useSsl) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF428B7C),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'SSL',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'کاربر: ${connection.username}',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 14,
                      ),
                    ),
                    if (provider.deviceIp != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'IP دستگاه شما: ${provider.deviceIp}',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            // Tab Bar و لیست دستگاه‌ها
            Expanded(
              child: Column(
                children: [
                  // دکمه قفل اتصال جدید
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: provider.isLoading
                                ? null
                                : () async {
                                    if (provider.isNewConnectionsLocked) {
                                      // رفع قفل
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('رفع قفل اتصال جدید'),
                                          content: const Text(
                                            'آیا مطمئن هستید که می‌خواهید قفل اتصال جدید را بردارید؟\n'
                                            'بعد از رفع قفل، دستگاه‌های جدید می‌توانند به شبکه متصل شوند.',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context, false),
                                              child: const Text('لغو'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(context, true),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.green,
                                                foregroundColor: Colors.white,
                                              ),
                                              child: const Text('رفع قفل'),
                                            ),
                                          ],
                                        ),
                                      );

                                      if (confirmed == true) {
                                        final success = await provider.unlockNewConnections();
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Row(
                                                children: [
                                                  Icon(
                                                    success ? Icons.check_circle : Icons.error,
                                                    color: Colors.white,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      success
                                                          ? 'قفل اتصال جدید با موفقیت برداشته شد'
                                                          : 'خطا در رفع قفل: ${provider.errorMessage ?? "خطا"}',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              backgroundColor: success ? Colors.green : Colors.red,
                                              behavior: SnackBarBehavior.floating,
                                            ),
                                          );
                                        }
                                      }
                                    } else {
                                      // فعال کردن قفل
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('قفل اتصال جدید'),
                                          content: const Text(
                                            'آیا مطمئن هستید که می‌خواهید اتصال دستگاه‌های جدید را قفل کنید؟\n\n'
                                            'بعد از فعال‌سازی:\n'
                                            '• دستگاه‌های فعلی همچنان کار می‌کنند\n'
                                            '• هیچ دستگاه جدیدی نمی‌تواند به وای‌فای یا LAN متصل شود\n'
                                            '• دستگاه‌های جدید به صورت خودکار مسدود می‌شوند',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context, false),
                                              child: const Text('لغو'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(context, true),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.orange,
                                                foregroundColor: Colors.white,
                                              ),
                                              child: const Text('قفل کردن'),
                                            ),
                                          ],
                                        ),
                                      );

                                      if (confirmed == true) {
                                        final success = await provider.lockNewConnections();
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Row(
                                                children: [
                                                  Icon(
                                                    success ? Icons.check_circle : Icons.error,
                                                    color: Colors.white,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      success
                                                          ? 'قفل اتصال جدید با موفقیت فعال شد'
                                                          : 'خطا در قفل کردن: ${provider.errorMessage ?? "خطا"}',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              backgroundColor: success ? Colors.orange : Colors.red,
                                              behavior: SnackBarBehavior.floating,
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  },
                            icon: Icon(
                              provider.isNewConnectionsLocked
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 20,
                            ),
                            label: Text(
                              provider.isNewConnectionsLocked
                                  ? 'قفل اتصال جدید (فعال)'
                                  : 'قفل اتصال جدید',
                              style: const TextStyle(fontSize: 14),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: provider.isNewConnectionsLocked
                                  ? Colors.orange
                                  : Colors.grey.shade300,
                              foregroundColor: provider.isNewConnectionsLocked
                                  ? Colors.white
                                  : Colors.black87,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Tab Bar
                  Container(
                    width: double.infinity,
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildTabButton(
                            title: 'دستگاه‌های متصل',
                            count: provider.clients.length,
                            icon: Icons.devices,
                            isActive: _selectedTab == 0,
                            onTap: () {
                              setState(() {
                                _selectedTab = 0;
                              });
                            },
                          ),
                        ),
                        Expanded(
                          child: _buildTabButton(
                            title: 'دستگاه‌های مسدود',
                            count: provider.bannedClients.length,
                            icon: Icons.block,
                            isActive: _selectedTab == 1,
                            onTap: () {
                              setState(() {
                                _selectedTab = 1;
                              });
                              provider.loadBannedClients();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  // محتوای Tab
                  Expanded(
                    child: _selectedTab == 0
                        ? _buildConnectedDevicesTab(provider)
                        : _buildBannedDevicesTab(provider),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required String title,
    required int count,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF428B7C).withOpacity(0.1) : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isActive ? const Color(0xFF428B7C) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: isActive ? const Color(0xFF428B7C) : Colors.grey.shade600,
            ),
            const SizedBox(width: 8),
            Text(
              '$title ($count)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? const Color(0xFF428B7C) : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedDevicesTab(ClientsProvider provider) {
    if (provider.isLoading || !provider.isDataComplete) {
      return Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: 5,
              itemBuilder: (context, index) {
                return _buildSkeletonCard();
              },
            ),
          ),
        ],
      );
    }

    if (provider.errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.grey.shade600,
              ),
              const SizedBox(height: 16),
              Text(
                provider.errorMessage!,
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => provider.loadClients(),
                icon: const Icon(Icons.refresh),
                label: const Text('تلاش مجدد'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF428B7C),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (provider.clients.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              'هیچ دستگاه متصلی یافت نشد',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 18,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.refresh(),
      color: const Color(0xFF428B7C),
      child: ListView.builder(
        itemCount: provider.clients.length,
        itemBuilder: (context, index) {
          final client = provider.clients[index];
          return _buildClientCard(client, provider.deviceIp);
        },
      ),
    );
  }

  Widget _buildBannedDevicesTab(ClientsProvider provider) {
    if (provider.bannedClients.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.block_outlined,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              'هیچ دستگاه مسدود شده‌ای یافت نشد',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 18,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.loadBannedClients(),
      color: const Color(0xFF428B7C),
      child: ListView.builder(
        itemCount: provider.bannedClients.length,
        itemBuilder: (context, index) {
          final banned = provider.bannedClients[index];
          return _buildBannedClientCard(banned);
        },
      ),
    );
  }

  Widget _buildBannedClientCard(Map<String, dynamic> banned) {
    final ipAddress = banned['address']?.toString();
    final macAddress = banned['mac_address']?.toString();
    final hostName = banned['host_name'] ?? banned['hostname'];

    // ساخت ClientInfo از banned device
    final bannedDevice = ClientInfo(
      type: 'banned',
      source: 'banned',
      ipAddress: ipAddress,
      macAddress: macAddress,
      hostName: hostName?.toString(),
      rawData: banned,
    );

    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () {
          Navigator.pushNamed(
            context,
            '/device-detail',
            arguments: {
              'device': bannedDevice,
              'isCurrentDevice': false,
              'isBanned': true,
            },
          );
        },
        splashColor: Colors.red.withOpacity(0.1),
        highlightColor: Colors.red.withOpacity(0.05),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // آیکون مسدود شده
              CircleAvatar(
                backgroundColor: Colors.red.withOpacity(0.2),
                child: const Icon(
                  Icons.block,
                  color: Colors.red,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              // اطلاعات دستگاه
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            hostName ?? ipAddress ?? 'دستگاه مسدود شده',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.red,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'مسدود',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (ipAddress != null && ipAddress.isNotEmpty)
                      Text(
                        'IP: $ipAddress',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    if (macAddress != null && macAddress.isNotEmpty)
                      Text(
                        'MAC: $macAddress',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    // نمایش نوع مسدودیت (Auto-banned یا Manual)
                    if (banned['comment'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(
                              banned['comment'].toString().contains('Auto-banned: New connection while locked')
                                  ? Icons.auto_fix_high
                                  : Icons.block,
                              size: 14,
                              color: banned['comment'].toString().contains('Auto-banned: New connection while locked')
                                  ? Colors.orange
                                  : Colors.red,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              banned['comment'].toString().contains('Auto-banned: New connection while locked')
                                  ? 'مسدود خودکار (قفل اتصال جدید)'
                                  : 'مسدود دستی',
                              style: TextStyle(
                                fontSize: 11,
                                color: banned['comment'].toString().contains('Auto-banned: New connection while locked')
                                    ? Colors.orange.shade700
                                    : Colors.red.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // دکمه رفع مسدودیت سریع
              IconButton(
                icon: const Icon(Icons.lock_open, color: Colors.green),
                tooltip: 'رفع مسدودیت',
                onPressed: () async {
                  if (ipAddress == null) return;
                  
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('رفع مسدودیت دستگاه'),
                      content: Text(
                        'آیا مطمئن هستید که می‌خواهید مسدودیت دستگاه ${ipAddress} را بردارید؟',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('لغو'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('رفع مسدودیت'),
                        ),
                      ],
                    ),
                  );

                  if (confirmed == true) {
                    try {
                      final provider = Provider.of<ClientsProvider>(context, listen: false);
                      final success = await provider.unbanClient(
                        ipAddress,
                        macAddress: macAddress,
                        hostname: hostName?.toString(),
                        ssid: banned['ssid']?.toString(),
                      );
                      
                      if (mounted) {
                        if (success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('مسدودیت دستگاه با موفقیت برداشته شد'),
                              backgroundColor: Colors.green,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          // به‌روزرسانی لیست
                          provider.loadBannedClients();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('خطا: ${provider.errorMessage ?? "خطا در رفع مسدودیت"}'),
                              backgroundColor: Colors.red,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('خطا: $e'),
                            backgroundColor: Colors.red,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  }
                },
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClientCard(ClientInfo client, String? deviceIp) {
    Color typeColor;
    IconData typeIcon;
    String typeLabel;
    final bool isCurrentDevice = deviceIp != null && client.ipAddress == deviceIp;

    switch (client.type) {
      case 'wireless':
        typeColor = Colors.green;
        typeIcon = Icons.wifi;
        typeLabel = 'Wireless';
        break;
      case 'dhcp':
        typeColor = Colors.orange;
        typeIcon = Icons.lan;
        typeLabel = 'DHCP';
        break;
      case 'hotspot':
        typeColor = Colors.purple;
        typeIcon = Icons.router;
        typeLabel = 'Hotspot';
        break;
      case 'ppp':
        typeColor = Colors.blue;
        typeIcon = Icons.phone;
        typeLabel = 'PPP';
        break;
      default:
        typeColor = Colors.grey;
        typeIcon = Icons.device_unknown;
        typeLabel = 'نامشخص';
    }

    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () {
          Navigator.pushNamed(
            context,
            '/device-detail',
            arguments: {
              'device': client,
              'isCurrentDevice': isCurrentDevice,
            },
          );
        },
        splashColor: const Color(0xFF428B7C).withOpacity(0.1),
        highlightColor: const Color(0xFF428B7C).withOpacity(0.05),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
          children: [
            // آیکون دستگاه
            Stack(
              children: [
                CircleAvatar(
                  backgroundColor: isCurrentDevice
                      ? const Color(0xFF428B7C).withOpacity(0.2)
                      : typeColor.withOpacity(0.2),
                  child: Icon(
                    typeIcon,
                    color: isCurrentDevice ? const Color(0xFF428B7C) : typeColor,
                    size: 24,
                  ),
                ),
                if (isCurrentDevice)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Color(0xFF428B7C),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            // اطلاعات دستگاه
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _getDeviceDisplayName(client),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: isCurrentDevice
                                ? const Color(0xFF428B7C)
                                : Colors.black87,
                          ),
                        ),
                      ),
                      if (isCurrentDevice)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF428B7C),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'شما',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (client.ipAddress != null)
                    Text(
                      'IP: ${client.ipAddress}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  if (client.macAddress != null)
                    Text(
                      'MAC: ${client.macAddress}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                ],
              ),
            ),
            // نوع دستگاه
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: typeColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                typeLabel,
                style: TextStyle(
                  color: typeColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              color: Colors.grey,
            ),
          ],
        ),
        ),
      ),
    );
  }

  String _getDeviceDisplayName(ClientInfo client) {
    // اولویت: hostName > user > name > IP > MAC
    if (client.hostName != null && client.hostName!.isNotEmpty) {
      return client.hostName!;
    }
    if (client.user != null && client.user!.isNotEmpty) {
      return client.user!;
    }
    if (client.name != null && client.name!.isNotEmpty) {
      return client.name!;
    }
    if (client.ipAddress != null && client.ipAddress!.isNotEmpty) {
      return 'دستگاه ${client.ipAddress}';
    }
    if (client.macAddress != null && client.macAddress!.isNotEmpty) {
      return 'دستگاه ${client.macAddress}';
    }
    return 'دستگاه ناشناس';
  }

  Widget _buildSkeletonCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          // Skeleton آیکون
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 16),
          // Skeleton اطلاعات
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 120,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 100,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Skeleton نوع دستگاه
          Container(
            width: 60,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
