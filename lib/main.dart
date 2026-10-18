import 'dart:async';

/// Internet Management Application
///
/// Developer: Mersad Karimi
/// Email: mersadkarimi001@gmail.com
///
/// A Flutter application for managing internet connections and MikroTik routers.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'screens/login_screen.dart';
import 'screens/connection_test_screen.dart';
import 'screens/device_detail_screen.dart';
import 'screens/internet_service_screen.dart';
import 'screens/app_settings_screen.dart';
import 'screens/wifi_settings_screen.dart';
import 'services/mikrotik_service_manager.dart';
import 'services/settings_service.dart';
import 'services/network_info_service.dart';
import 'models/client_info.dart';
import 'providers/clients_provider.dart';
import 'utils/device_list_pagination.dart';
import 'utils/client_display_name.dart';
import 'utils/app_localizations.dart';
import 'utils/app_theme.dart';
import 'widgets/client_live_traffic_badge.dart';
import 'widgets/traffic_list_item_visibility.dart';
import 'utils/wifi_panel_url_resolver.dart';
import 'utils/webview_environment.dart';

// 全局回调函数，用于从子组件通知主应用更改语言
Function(Locale)? onLanguageChanged;

// 全局回调函数，用于从子组件通知主应用更改主题
Function(ThemeMode)? onThemeChanged;

final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureWindowsWebViewEnvironment();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SettingsService _settingsService = SettingsService();
  Locale _locale = const Locale('fa', 'IR'); // 默认语言：波斯语
  ThemeMode _themeMode = ThemeMode.light; // 默认主题：跟随系统
  bool _isLoading = true;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 注册全局回调
    onLanguageChanged = (Locale newLocale) {
      changeLanguage(newLocale);
    };
    onThemeChanged = (ThemeMode newThemeMode) {
      changeTheme(newThemeMode);
    };
    _loadSettings();
    _logNetworkInfoOnStartup();
  }

  /// لاگ اطلاعات شبکه به محض باز شدن برنامه
  Future<void> _logNetworkInfoOnStartup() async {
    try {
      print('═══════════════════════════════════════════════════════');
      print('🚀 [APP_STARTUP] برنامه در حال راه‌اندازی...');
      print('═══════════════════════════════════════════════════════');

      final networkInfo = NetworkInfoService();

      // دریافت IPv4 Address دستگاه
      final deviceIp = await networkInfo.getDeviceIPv4Address();
      if (deviceIp != null) {
        print('✅ [APP_STARTUP] IPv4 Address دستگاه کاربر: $deviceIp');
      } else {
        print('⚠️ [APP_STARTUP] IPv4 Address دستگاه کاربر: یافت نشد');
      }

      final gatewayDiscovery = await networkInfo.discoverDeviceDefaultGateway();
      if (gatewayDiscovery.found) {
        print(
          '✅ [APP_STARTUP] Default Gateway اینترنت: ${gatewayDiscovery.ip}',
        );
        print(
          '   └─ منبع: ${networkInfo.sourceLabel(gatewayDiscovery.source)}',
        );
      } else {
        print('⚠️ [APP_STARTUP] Default Gateway اینترنت: یافت نشد (OS)');
      }

      // دریافت تنظیمات اتصال
      final settings = await _settingsService.getAllSettings();
      print('📋 [APP_STARTUP] تنظیمات اتصال:');
      print('   └─ Router Host: ${settings['host']}');
      print('   └─ Router Port: ${settings['port']}');
      print('   └─ Use SSL: ${settings['useSsl']}');

      print('═══════════════════════════════════════════════════════');
    } catch (e) {
      print('❌ [APP_STARTUP] خطا در دریافت اطلاعات شبکه: $e');
    }
  }

  @override
  void dispose() {
    onLanguageChanged = null;
    onThemeChanged = null;
    super.dispose();
  }

  /// 加载保存的设置（语言和主题）
  Future<void> _loadSettings() async {
    try {
      // 加载语言设置
      final languageCode = await _settingsService.getLanguage();
      final locale = languageCode == 'en'
          ? const Locale('en', 'US')
          : const Locale('fa', 'IR');

      // 加载主题设置
      final themeMode = await _settingsService.getThemeModeEnum();

      setState(() {
        _locale = locale;
        _themeMode = themeMode;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _locale = const Locale('fa', 'IR');
        _themeMode = ThemeMode.light;
        _isLoading = false;
      });
    }
  }

  /// 更改语言（供子组件调用）
  Future<void> changeLanguage(Locale newLocale) async {
    await _settingsService.setLanguage(newLocale.languageCode);
    setState(() {
      _locale = newLocale;
    });
  }

  /// 更改主题（供子组件调用）
  Future<void> changeTheme(ThemeMode newThemeMode) async {
    await _settingsService.setThemeModeEnum(newThemeMode);
    setState(() {
      _themeMode = newThemeMode;
    });
  }

  TextTheme? get _localizedTextTheme => _locale.languageCode == 'fa'
      ? const TextTheme(
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
        )
      : null;

  @override
  Widget build(BuildContext context) {
    final localizedTextTheme = _localizedTextTheme;

    if (_isLoading) {
      // 显示加载指示器，直到语言加载完成
      return MaterialApp(
        theme: AppTheme.buildTheme(
          brightness: Brightness.light,
          fontFamily: _locale.languageCode == 'fa' ? 'Vazir' : null,
          textTheme: localizedTextTheme,
        ),
        darkTheme: AppTheme.buildTheme(
          brightness: Brightness.dark,
          fontFamily: _locale.languageCode == 'fa' ? 'Vazir' : null,
          textTheme: localizedTextTheme,
        ),
        themeMode: _themeMode,
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(color: AppTheme.primary),
          ),
        ),
      );
    }

    return ChangeNotifierProvider(
      create: (_) => ClientsProvider(),
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'Internet Management',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.buildTheme(
          brightness: Brightness.light,
          fontFamily: _locale.languageCode == 'fa' ? 'Vazir' : null,
          textTheme: localizedTextTheme,
        ),
        darkTheme: AppTheme.buildTheme(
          brightness: Brightness.dark,
          fontFamily: _locale.languageCode == 'fa' ? 'Vazir' : null,
          textTheme: localizedTextTheme,
        ),
        themeMode: _themeMode,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          AppLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('fa', 'IR'), // فارسی
          Locale('en', 'US'), // انگلیسی
        ],
        locale: _locale,
        navigatorObservers: [routeObserver],
        initialRoute: '/',
        routes: {
          '/': (context) => const SplashScreen(),
          '/login': (context) => const LoginScreen(),
          '/home': (context) => const MainScaffold(),
          '/test': (context) => const ConnectionTestScreen(),
          '/device-detail': (context) {
            final args =
                ModalRoute.of(context)!.settings.arguments
                    as Map<String, dynamic>;
            return DeviceDetailScreen(
              device: args['device'] as ClientInfo,
              isCurrentDevice: args['isCurrentDevice'] as bool? ?? false,
              isBanned: args['isBanned'] as bool? ?? false,
            );
          },
          '/wifi-settings': (context) => const WifiSettingsRouter(),
          '/wifi-webview': (context) => const InternetServiceScreen(
            fixedUrl: WifiPanelUrlResolver.cpeWifiPanelUrl,
            defaultTitle: 'اطلاعات Wifi',
            allowUrlChange: false,
          ),
        },
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          final textScaler = switch (defaultTargetPlatform) {
            TargetPlatform.windows ||
            TargetPlatform.linux ||
            TargetPlatform.macOS => mediaQuery.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.2,
            ),
            _ => mediaQuery.textScaler.clamp(
              minScaleFactor: 0.95,
              maxScaleFactor: 1.1,
            ),
          };
          return MediaQuery(
            data: mediaQuery.copyWith(textScaler: textScaler),
            child: child!,
          );
        },
      ),
    );
  }
}

/// صفحه splash — تلاش auto-login قبل از Login یا Home
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _attemptAutoLogin();
  }

  Future<void> _attemptAutoLogin() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));

    if (!mounted) {
      return;
    }

    final manager = MikroTikServiceManager();
    final success = await manager.autoConnect();

    if (!mounted) {
      return;
    }

    if (success && manager.isConnected) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      if (success && !manager.isConnected) {
        debugPrint('[AUTO_LOGIN] connect returned true but session is dead');
      }
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              isDark
                  ? 'assets/images/logos/logo_dark.png'
                  : 'assets/images/logos/logo.png',
              width: 120,
              height: 120,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: AppTheme.primary),
          ],
        ),
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

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLoginExpiration();
    _loadNetworkInfo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!mounted) {
      return;
    }

    final provider = Provider.of<ClientsProvider>(context, listen: false);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      provider.stopOnlineStatusTimer();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (provider.isConnected && provider.clients.isNotEmpty) {
        provider.startOnlineStatusTimer();
        provider.refreshOnlineStatus();
      }
    }
  }

  /// بارگذاری اطلاعات شبکه (IPv4 Address و Default Gateway)
  /// این متد هنگام باز شدن برنامه اطلاعات شبکه را دریافت می‌کند
  Future<void> _loadNetworkInfo() async {
    try {
      print('═══════════════════════════════════════════════════════');
      print('🌐 [NETWORK_INFO] در حال دریافت اطلاعات شبکه دستگاه...');
      print('═══════════════════════════════════════════════════════');

      final networkInfo = NetworkInfoService();

      // دریافت IPv4 Address دستگاه
      final deviceIp = await networkInfo.getDeviceIPv4Address();
      if (deviceIp != null) {
        print('✅ [NETWORK_INFO] IPv4 Address دستگاه کاربر: $deviceIp');
      } else {
        print('⚠️ [NETWORK_INFO] IPv4 Address دستگاه کاربر: یافت نشد');
      }

      final gatewayDiscovery = await networkInfo.discoverDeviceDefaultGateway();
      if (gatewayDiscovery.found) {
        print(
          '✅ [NETWORK_INFO] Default Gateway اینترنت: ${gatewayDiscovery.ip}',
        );
        print(
          '   └─ منبع: ${networkInfo.sourceLabel(gatewayDiscovery.source)}',
        );
      } else {
        print('⚠️ [NETWORK_INFO] Default Gateway اینترنت: یافت نشد (OS)');
      }

      // بررسی وضعیت اتصال RouterOS
      if (_serviceManager.isConnected) {
        print('✅ [NETWORK_INFO] اتصال به RouterOS: برقرار است');
        final routerInfo = _serviceManager.routerInfo;
        if (routerInfo != null) {
          print('   └─ Router Version: ${routerInfo['version']}');
          print('   └─ Router Platform: ${routerInfo['platform']}');
          print('   └─ Router Uptime: ${routerInfo['uptime']}');
        }
      } else {
        print('⚠️ [NETWORK_INFO] اتصال به RouterOS: برقرار نیست');
      }

      // دریافت همه اطلاعات شبکه
      final allInfo = await networkInfo.getNetworkInfo();
      print('📊 [NETWORK_INFO] خلاصه اطلاعات شبکه:');
      print('   └─ Device IPv4: ${allInfo['deviceIp'] ?? 'N/A'}');
      print('   └─ Default Gateway: ${allInfo['defaultGateway'] ?? 'N/A'}');
      print('   └─ Gateway Source: ${allInfo['gatewaySource'] ?? 'N/A'}');

      print('═══════════════════════════════════════════════════════');
    } catch (e) {
      print('❌ [NETWORK_INFO] خطا در دریافت اطلاعات شبکه: $e');
    }
  }

  /// بررسی انقضای لاگین
  Future<void> _checkLoginExpiration() async {
    final timestamp = await _settingsService.getLoginTimestamp();
    if (timestamp == null && _serviceManager.isConnected) {
      await _settingsService.setLoginTimestamp();
      return;
    }

    final isExpired = await _settingsService.isLoginExpired();
    if (isExpired && mounted) {
      // اگر لاگین منقضی شده باشد، به صفحه ورود هدایت کن
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      provider.clear();
      _serviceManager.disconnect();
      await _settingsService.clearLoginTimestamp();
      if (!await _settingsService.getRememberMe()) {
        await _settingsService.clearCredentials();
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    }
  }

  void _onTabTapped(int index) {
    if (_currentIndex == index) {
      return;
    }

    setState(() {
      _currentIndex = index;
    });

    if (index == 0) {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      unawaited(provider.onHomeTabActivated());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          HomePage(),
          InternetServiceScreen(),
          AppSettingsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        color: Colors.transparent,
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? colorScheme.surface.withOpacity(0.96)
                  : Colors.white.withOpacity(0.96),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(
                  theme.brightness == Brightness.dark ? 0.35 : 0.55,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.brightness == Brightness.dark
                      ? Colors.black.withOpacity(0.28)
                      : AppTheme.primary.withOpacity(0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  _buildNavItem(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home_rounded,
                    index: 0,
                    isActive: _currentIndex == 0,
                  ),
                  _buildNavItem(
                    icon: Icons.public_outlined,
                    activeIcon: Icons.public_rounded,
                    index: 1,
                    isActive: _currentIndex == 1,
                  ),
                  _buildNavItem(
                    icon: Icons.settings_outlined,
                    activeIcon: Icons.settings,
                    index: 2,
                    isActive: _currentIndex == 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required IconData activeIcon,
    required int index,
    required bool isActive,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primaryColor = AppTheme.primaryFor(theme.brightness);

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: () => _onTabTapped(index),
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: isActive
                  ? LinearGradient(
                      colors: [
                        primaryColor,
                        Color.lerp(
                              primaryColor,
                              Colors.white,
                              theme.brightness == Brightness.dark ? 0.16 : 0.08,
                            ) ??
                            primaryColor,
                      ],
                    )
                  : null,
              color: isActive ? null : Colors.transparent,
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: primaryColor.withOpacity(
                          theme.brightness == Brightness.dark ? 0.28 : 0.2,
                        ),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isActive
                        ? Colors.white.withOpacity(0.2)
                        : (theme.brightness == Brightness.dark
                              ? colorScheme.surfaceContainerHighest
                              : primaryColor.withOpacity(0.15)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    isActive ? activeIcon : icon,
                    color: isActive ? Colors.white : primaryColor,
                    size: 30,
                  ),
                ),
              ],
            ),
          ),
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

class _HomePageState extends State<HomePage> with RouteAware {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  int _selectedTab = 0; // 0: متصل, 1: مسدود
  bool _routeObserverSubscribed = false;
  late final ScrollController _connectedScrollController;
  late final ScrollController _bannedScrollController;

  @override
  void initState() {
    super.initState();
    _connectedScrollController = ScrollController();
    _bannedScrollController = ScrollController();
    _connectedScrollController.addListener(_onConnectedScroll);
    _bannedScrollController.addListener(_onBannedScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      unawaited(provider.prefetchTabCounts());
      if (!provider.phase1Complete &&
          !provider.isLoading &&
          provider.clients.isEmpty) {
        provider.initialize();
      } else if (_connectedScrollController.hasClients) {
        final position = _connectedScrollController.position;
        provider.updateTrafficViewportFromScroll(
          scrollOffset: position.pixels,
          viewportHeight: position.viewportDimension,
        );
      }
    });
  }

  void _onConnectedScroll() {
    if (!_connectedScrollController.hasClients) {
      return;
    }
    final provider = Provider.of<ClientsProvider>(context, listen: false);
    final position = _connectedScrollController.position;

    provider.updateTrafficViewportFromScroll(
      scrollOffset: position.pixels,
      viewportHeight: position.viewportDimension,
    );

    final estimatedFirst =
        (position.pixels / DeviceListPagination.estimatedRowHeight).floor();
    final estimatedVisible =
        (position.viewportDimension / DeviceListPagination.estimatedRowHeight)
            .ceil();
    provider.ensureConnectedVisibleThrough(estimatedFirst + estimatedVisible);

    if (position.maxScrollExtent - position.pixels < 240) {
      provider.loadMoreConnectedDevices();
    }
  }

  void _onBannedScroll() {
    if (!_bannedScrollController.hasClients) {
      return;
    }
    final provider = Provider.of<ClientsProvider>(context, listen: false);
    final position = _bannedScrollController.position;
    if (position.maxScrollExtent - position.pixels < 240) {
      provider.loadMoreBannedDevices();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeObserverSubscribed) {
      return;
    }

    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      routeObserver.subscribe(this, route);
      _routeObserverSubscribed = true;
    }
  }

  @override
  void dispose() {
    if (_routeObserverSubscribed) {
      routeObserver.unsubscribe(this);
    }
    _connectedScrollController.removeListener(_onConnectedScroll);
    _bannedScrollController.removeListener(_onBannedScroll);
    _connectedScrollController.dispose();
    _bannedScrollController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    _restoreHomeAfterOverlay();
  }

  /// Overlay (device detail) closed — restore traffic viewport, do not refetch.
  void _restoreHomeAfterOverlay() {
    if (!mounted) {
      return;
    }
    final provider = Provider.of<ClientsProvider>(context, listen: false);

    if (_selectedTab == 0 && _connectedScrollController.hasClients) {
      final position = _connectedScrollController.position;
      provider.updateTrafficViewportFromScroll(
        scrollOffset: position.pixels,
        viewportHeight: position.viewportDimension,
      );
    }

    provider.resumeAfterOverlay();
  }

  Widget _buildPullToRefresh({
    required Widget child,
    required Future<void> Function() onRefresh,
  }) {
    return RefreshIndicator.adaptive(
      color: AppTheme.primary,
      onRefresh: onRefresh,
      child: child,
    );
  }

  void _switchHomeTab(int index) {
    if (_selectedTab == index) {
      return;
    }

    setState(() {
      _selectedTab = index;
    });

    if (index == 1) {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      unawaited(provider.ensureBannedListLoaded());
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = _serviceManager.currentConnection;
    final provider = Provider.of<ClientsProvider>(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.primaryFor(theme.brightness),
            boxShadow: [
              BoxShadow(
                color: theme.brightness == Brightness.dark
                    ? Colors.black.withOpacity(0.3)
                    : Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Builder(
            builder: (context) {
              final l10n = AppLocalizations.of(context);
              return AppBar(
                title: Text(
                  l10n?.appTitle ?? 'Internet Management',
                  style: TextStyle(
                    color: theme.brightness == Brightness.dark
                        ? colorScheme.onSurface
                        : Colors.white,
                  ),
                ),
                backgroundColor: Colors.transparent,
                foregroundColor: theme.brightness == Brightness.dark
                    ? colorScheme.onSurface
                    : Colors.white,
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
              );
            },
          ),
        ),
      ),
      body: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return Container(
            color: colorScheme.surfaceContainerHighest,
            child: Column(
              children: [
                // اطلاعات اتصال
                if (connection != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: colorScheme.surface,
                    child: !provider.phase3Complete
                        ? _buildConnectionHeaderSkeleton(context)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.router,
                                    color: colorScheme.primary,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          provider.routerInfo?['identity'] !=
                                                      null &&
                                                  provider.routerInfo!['identity'] !=
                                                      'Unknown' &&
                                                  provider
                                                      .routerInfo!['identity']!
                                                      .toString()
                                                      .isNotEmpty
                                              ? provider
                                                    .routerInfo!['identity']!
                                              : provider.routerInfo?['board-name'] !=
                                                        null &&
                                                    provider.routerInfo!['board-name'] !=
                                                        'Unknown'
                                              ? provider
                                                    .routerInfo!['board-name']!
                                              : '${connection.host}:${connection.port}',
                                          style: TextStyle(
                                            color:
                                                theme.brightness ==
                                                    Brightness.dark
                                                ? colorScheme.onSurface
                                                : Colors.black87,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
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
                                        color: colorScheme.primary,
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
                              Builder(
                                builder: (context) {
                                  final l10n = AppLocalizations.of(context);
                                  return Text(
                                    '${l10n?.user ?? 'User'}: ${connection.username}',
                                    style: TextStyle(
                                      color: theme.brightness == Brightness.dark
                                          ? colorScheme.onSurface.withOpacity(
                                              0.7,
                                            )
                                          : Colors.grey.shade700,
                                      fontSize: 14,
                                    ),
                                  );
                                },
                              ),
                              if (provider.deviceIp != null) ...[
                                const SizedBox(height: 4),
                                Builder(
                                  builder: (context) {
                                    final l10n = AppLocalizations.of(context);
                                    return Text(
                                      '${l10n?.yourDeviceIP ?? 'Your Device IP'}: ${provider.deviceIp}',
                                      style: TextStyle(
                                        color:
                                            theme.brightness == Brightness.dark
                                            ? colorScheme.onSurface.withOpacity(
                                                0.6,
                                              )
                                            : Colors.grey.shade600,
                                        fontSize: 12,
                                      ),
                                    );
                                  },
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        color: colorScheme.surface,
                        child: Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed:
                                    (!provider.phase1Complete &&
                                            provider.isLoading) ||
                                        provider.isLockUpdating
                                    ? null
                                    : () async {
                                        final l10n = AppLocalizations.of(
                                          context,
                                        );
                                        final messenger = ScaffoldMessenger.of(
                                          context,
                                        );
                                        final activating =
                                            !provider.isNewConnectionsLocked;
                                        final success = await provider
                                            .toggleNewConnectionsLock();
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              success
                                                  ? (activating
                                                        ? (l10n?.lockNewConnectionsEnabled ??
                                                              'New connections locked')
                                                        : (l10n?.lockNewConnectionsDisabled ??
                                                              'New connections unlocked'))
                                                  : (provider.errorMessage ??
                                                        (l10n?.lockStatusError ??
                                                            'Error changing lock status')),
                                            ),
                                            backgroundColor: success
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : Colors.red,
                                            behavior: SnackBarBehavior.floating,
                                          ),
                                        );
                                      },
                                icon: provider.isLockUpdating
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Icon(
                                        provider.isNewConnectionsLocked
                                            ? Icons.lock
                                            : Icons.lock_open,
                                        size: 20,
                                      ),
                                label: Builder(
                                  builder: (context) {
                                    final l10n = AppLocalizations.of(context);
                                    return Text(
                                      provider.isNewConnectionsLocked
                                          ? (l10n?.lockNewConnectionsActive ??
                                                'Lock New Connections (Active)')
                                          : (l10n?.lockNewConnections ??
                                                'Lock New Connections'),
                                      style: const TextStyle(fontSize: 14),
                                    );
                                  },
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      provider.isNewConnectionsLocked
                                      ? Colors.red.shade600
                                      : (theme.brightness == Brightness.dark
                                            ? colorScheme
                                                  .surfaceContainerHighest
                                            : Colors.grey.shade300),
                                  foregroundColor:
                                      provider.isNewConnectionsLocked
                                      ? Colors.white
                                      : (theme.brightness == Brightness.dark
                                            ? colorScheme.onSurface
                                            : Colors.black87),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
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
                      Builder(
                        builder: (context) {
                          final theme = Theme.of(context);
                          final colorScheme = theme.colorScheme;

                          return Container(
                            width: double.infinity,
                            color: colorScheme.surface,
                            child: Row(
                              mainAxisSize: MainAxisSize.max,
                              children: [
                                Expanded(
                                  flex: 1,
                                  child: Builder(
                                    builder: (context) {
                                      final l10n = AppLocalizations.of(context);
                                      return _buildTabButton(
                                        title: l10n?.locale.languageCode == 'fa'
                                            ? 'متصل'
                                            : (l10n?.connectedDevices ??
                                                  'Connected'),
                                        count: provider.connectedTabCount,
                                        icon: Icons.devices,
                                        isActive: _selectedTab == 0,
                                        onTap: () => _switchHomeTab(0),
                                      );
                                    },
                                  ),
                                ),
                                Expanded(
                                  flex: 1,
                                  child: Builder(
                                    builder: (context) {
                                      final l10n = AppLocalizations.of(context);
                                      return _buildTabButton(
                                        title: l10n?.locale.languageCode == 'fa'
                                            ? 'مسدود'
                                            : (l10n?.bannedDevices ?? 'Banned'),
                                        count: provider.bannedTabCount,
                                        icon: Icons.block,
                                        isActive: _selectedTab == 1,
                                        onTap: () => _switchHomeTab(1),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      // محتوای Tab
                      Expanded(
                        child: IndexedStack(
                          index: _selectedTab,
                          children: [
                            _buildConnectedDevicesTab(provider),
                            _buildBannedDevicesTab(provider),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
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
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final primaryColor = AppTheme.primaryFor(theme.brightness);

        // تشخیص اندازه صفحه برای ریسپانسیو کردن
        final screenWidth = MediaQuery.of(context).size.width;
        final isSmallScreen = screenWidth < 360; // برای S8 و صفحه‌های کوچک‌تر

        // تنظیم فونت و آیکون بر اساس اندازه صفحه
        // فقط کمی کوچک‌تر می‌کنیم برای صفحه‌های کوچک (S8)
        final fontSize = isSmallScreen ? 13.0 : 15.0;
        final iconSize = isSmallScreen ? 18.0 : 20.0;
        final padding = isSmallScreen
            ? const EdgeInsets.symmetric(vertical: 12, horizontal: 4)
            : const EdgeInsets.symmetric(vertical: 16);
        final spacing = isSmallScreen ? 6.0 : 8.0;

        return InkWell(
          onTap: onTap,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: isActive
                  ? (theme.brightness == Brightness.dark
                        ? primaryColor.withOpacity(0.2)
                        : primaryColor.withOpacity(0.1))
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(
                  color: isActive ? primaryColor : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: iconSize,
                  color: isActive
                      ? primaryColor
                      : (theme.brightness == Brightness.dark
                            ? colorScheme.onSurface.withOpacity(0.6)
                            : Colors.grey.shade600),
                ),
                SizedBox(width: spacing),
                Flexible(
                  child: Text(
                    '$title ($count)',
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isActive
                          ? primaryColor
                          : (theme.brightness == Brightness.dark
                                ? colorScheme.onSurface.withOpacity(0.6)
                                : Colors.grey.shade600),
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    softWrap: false,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionHeaderSkeleton(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _SkeletonBox(width: 20, height: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [_SkeletonBox(width: 160, height: 16)],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _SkeletonBox(width: 140, height: 12),
      ],
    );
  }

  Widget _buildConnectedDevicesTab(ClientsProvider provider) {
    // نمایش skeleton فقط در حالت initial loading
    if (provider.isLoading &&
        !provider.phase1Complete &&
        provider.clients.isEmpty) {
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

    // اگر در حال progressive loading هستیم و لیست خالی نیست، لیست فعلی را نمایش بده
    // (progressive loading در پس‌زمینه ادامه می‌دهد)

    if (provider.errorMessage != null && provider.clients.isEmpty) {
      return Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: theme.brightness == Brightness.dark
                        ? colorScheme.onSurface.withOpacity(0.6)
                        : Colors.grey.shade600,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    provider.errorMessage!,
                    style: TextStyle(
                      color: theme.brightness == Brightness.dark
                          ? colorScheme.onSurface.withOpacity(0.7)
                          : Colors.grey.shade700,
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Builder(
                    builder: (context) {
                      final l10n = AppLocalizations.of(context);
                      return ElevatedButton.icon(
                        onPressed: () => provider.initialize(),
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n?.retry ?? 'Retry'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (provider.clientsForDisplay.isEmpty) {
      return Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return _buildPullToRefresh(
            onRefresh: provider.refresh,
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 64,
                          color: theme.brightness == Brightness.dark
                              ? colorScheme.onSurface.withOpacity(0.4)
                              : Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Builder(
                          builder: (context) {
                            final l10n = AppLocalizations.of(context);
                            return Text(
                              l10n?.noConnectedDevices ??
                                  'No connected devices found',
                              style: TextStyle(
                                color: theme.brightness == Brightness.dark
                                    ? colorScheme.onSurface.withOpacity(0.6)
                                    : Colors.grey.shade600,
                                fontSize: 18,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return _buildPullToRefresh(
      onRefresh: provider.refresh,
      child: TrafficListScrollScope(
        controller: _connectedScrollController,
        child: ListView.builder(
          key: const PageStorageKey<String>('home-connected-list'),
          controller: _connectedScrollController,
          cacheExtent: 500,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          itemCount: _connectedListItemCount(provider),
          itemBuilder: (context, index) {
            final clients = provider.clientsForDisplay;
            if (index >= clients.length) {
              return _buildConnectedListFooter(provider);
            }

            provider.noteListItemVisible(index);
            provider.maybePrefetchConnectedAtIndex(index);
            final client = clients[index];
            final stableKey =
                client.macAddress ?? client.ipAddress ?? index.toString();
            return RepaintBoundary(
              key: ValueKey('client-$stableKey'),
              child: TrafficListItemVisibility(
                key: ValueKey('traffic-vis-$stableKey'),
                index: index,
                child: _buildClientCard(context, client, provider),
              ),
            );
          },
        ),
      ),
    );
  }

  int _connectedListItemCount(ClientsProvider provider) {
    var count = provider.clientsForDisplay.length;
    if (provider.hasMoreConnectedToShow) {
      count += 1;
    }
    return count;
  }

  Widget _buildConnectedListFooter(ClientsProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          '${provider.clientsForDisplay.length} / ${provider.totalConnectedCount}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  /// ساخت کارت اسکلتون برای نمایش در حالت بارگذاری
  Widget _buildSkeletonCard() {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.brightness == Brightness.dark
                    ? colorScheme.outline.withOpacity(0.2)
                    : Colors.grey.shade300,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // آیکون اسکلتون
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? colorScheme.onSurface.withOpacity(0.1)
                      : Colors.grey.shade300,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 16),
              // متن اسکلتون
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 16,
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? colorScheme.onSurface.withOpacity(0.1)
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 150,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? colorScheme.onSurface.withOpacity(0.1)
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBannedDevicesTab(ClientsProvider provider) {
    if (provider.showBannedLoadingSkeleton && provider.bannedClients.isEmpty) {
      return ListView.builder(
        itemCount: 4,
        itemBuilder: (context, index) => _buildSkeletonCard(),
      );
    }

    if (provider.bannedClients.isEmpty) {
      return _buildPullToRefresh(
        onRefresh: () => provider.ensureBannedListLoaded(force: true),
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
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
                      AppLocalizations.of(context)?.noBannedDevices ??
                          'No banned devices found',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return _buildPullToRefresh(
      onRefresh: () => provider.ensureBannedListLoaded(force: true),
      child: ListView.builder(
        key: const PageStorageKey<String>('home-banned-list'),
        controller: _bannedScrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: _bannedListItemCount(provider),
        itemBuilder: (context, index) {
          final bannedItems = provider.bannedClientsForDisplay;
          if (index >= bannedItems.length) {
            return _buildBannedListFooter(provider);
          }

          provider.maybePrefetchBannedAtIndex(index);
          return _buildBannedClientCard(bannedItems[index]);
        },
      ),
    );
  }

  int _bannedListItemCount(ClientsProvider provider) {
    var count = provider.bannedClientsForDisplay.length;
    if (provider.hasMoreBannedToShow || provider.isLoadingMoreBanned) {
      count += 1;
    }
    return count;
  }

  Widget _buildBannedListFooter(ClientsProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: provider.isLoadingMoreBanned
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                '${provider.bannedClientsForDisplay.length} / ${provider.bannedTabCount}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
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

    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        return Material(
          color: colorScheme.surface,
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
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.brightness == Brightness.dark
                        ? colorScheme.outline.withOpacity(0.2)
                        : Colors.grey.shade300,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // آیکون مسدود شده
                  CircleAvatar(
                    backgroundColor: Colors.red.withOpacity(0.2),
                    child: const Icon(Icons.block, color: Colors.red, size: 24),
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
                                hostName ??
                                    ipAddress ??
                                    AppLocalizations.of(
                                      context,
                                    )?.bannedDevice ??
                                    'Banned Device',
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
                              child: Text(
                                AppLocalizations.of(context)?.banned ??
                                    'Banned',
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
                              color: theme.brightness == Brightness.dark
                                  ? colorScheme.onSurface.withOpacity(0.7)
                                  : Colors.grey.shade600,
                            ),
                          ),
                        if (macAddress != null && macAddress.isNotEmpty)
                          Text(
                            'MAC: $macAddress',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.brightness == Brightness.dark
                                  ? colorScheme.onSurface.withOpacity(0.6)
                                  : Colors.grey.shade500,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // دکمه رفع مسدودیت سریع
                  Builder(
                    builder: (context) {
                      final l10n = AppLocalizations.of(context);
                      return IconButton(
                        icon: const Icon(
                          Icons.lock_open,
                          color: AppTheme.primary,
                        ),
                        tooltip: l10n?.unbanDeviceTooltip ?? 'Unban Device',
                        onPressed: () async {
                          if (ipAddress == null &&
                              (macAddress == null || macAddress.isEmpty)) {
                            return;
                          }

                          final targetLabel = ipAddress ?? macAddress!;
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: colorScheme.surface,
                              title: Text(
                                l10n?.unbanDeviceTitle ?? 'Unban Device',
                                style: TextStyle(color: colorScheme.onSurface),
                              ),
                              content: Text(
                                l10n?.unbanDeviceConfirmTextWithIP(
                                      targetLabel,
                                    ) ??
                                    'Are you sure you want to unban device $targetLabel?',
                                style: TextStyle(color: colorScheme.onSurface),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: Text(
                                    l10n?.cancel ?? 'Cancel',
                                    style: TextStyle(
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primary,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: Text(l10n?.unban ?? 'Unban'),
                                ),
                              ],
                            ),
                          );

                          if (confirmed == true) {
                            try {
                              final provider = Provider.of<ClientsProvider>(
                                context,
                                listen: false,
                              );
                              final success = await provider.unbanClient(
                                ipAddress ?? '',
                                macAddress: macAddress,
                                hostname: hostName?.toString(),
                                ssid: banned['ssid']?.toString(),
                              );

                              if (mounted) {
                                final l10n = AppLocalizations.of(context);
                                if (success) {
                                  provider.reconcileHomeListsAfterBanOrUnban();
                                  setState(() {
                                    _selectedTab = 0;
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(
                                            Icons.check_circle,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              l10n?.deviceUnbannedSuccess ??
                                                  'Device unbanned successfully',
                                            ),
                                          ),
                                        ],
                                      ),
                                      backgroundColor: AppTheme.primary,
                                      behavior: SnackBarBehavior.floating,
                                      duration: Duration(seconds: 3),
                                    ),
                                  );
                                  unawaited(
                                    provider.ensureBannedListLoaded(
                                      force: true,
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${l10n?.error ?? 'Error'}: ${provider.errorMessage ?? (l10n?.errorUnbanning ?? 'Error unbanning device')}',
                                      ),
                                      backgroundColor: Colors.red,
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            } catch (e) {
                              if (mounted) {
                                final l10n = AppLocalizations.of(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n?.error ?? 'Error'}: $e',
                                    ),
                                    backgroundColor: Colors.red,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            }
                          }
                        },
                      ); // 结束 return IconButton
                    },
                  ),
                  const SizedBox(width: 4),
                  Builder(
                    builder: (context) {
                      final theme = Theme.of(context);
                      final colorScheme = theme.colorScheme;

                      return Icon(
                        Icons.chevron_right,
                        color: theme.brightness == Brightness.dark
                            ? colorScheme.onSurface.withOpacity(0.4)
                            : Colors.grey,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOnlineStatusDot(ClientInfo device) {
    if (device.isOnline != true) {
      return const SizedBox.shrink();
    }

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF4CAF50),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }

  Widget _buildClientCard(
    BuildContext context,
    ClientInfo client,
    ClientsProvider provider,
  ) {
    const typeColor = Color(0xFF4CAF50);
    const typeIcon = Icons.wifi;
    final bool isCurrentDevice = provider.isCurrentDevice(client);
    final showPhase2Skeleton = !provider.phase2Complete;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isStatic = _isStaticDevice(client);
    final isPendingApproval = provider.isDevicePendingApproval(
      client,
      isCurrentDevice: isCurrentDevice,
    );
    final isApprovalBusy = provider.isApprovalActionInProgress(client);

    Future<void> openDeviceDetail() async {
      final result = await Navigator.pushNamed(
        context,
        '/device-detail',
        arguments: {'device': client, 'isCurrentDevice': isCurrentDevice},
      );

      if (!mounted) {
        return;
      }

      if (result is Map && result['action'] == 'banned') {
        provider.reconcileHomeListsAfterBanOrUnban();
        setState(() {
          _selectedTab = 1;
        });
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n?.deviceBannedSuccess ?? 'Device banned successfully',
            ),
            backgroundColor: AppTheme.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (result == true) {
        provider.reconcileHomeListsAfterBanOrUnban();
        setState(() {
          _selectedTab = 0;
        });
        return;
      }
    }

    Future<void> runPendingAction({required bool approve}) async {
      final l10n = AppLocalizations.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final success = approve
          ? await provider.approveDevice(client)
          : await provider.rejectDevice(client);
      if (!mounted) return;

      if (!approve && success) {
        setState(() {
          _selectedTab = 1;
        });
        unawaited(provider.ensureBannedListLoaded(force: true));
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? (approve
                      ? (l10n?.deviceApproved ?? 'Device approved')
                      : (l10n?.deviceRejected ?? 'Device rejected'))
                : (provider.errorMessage ??
                      (approve
                          ? (l10n?.approveError ?? 'Error approving device')
                          : (l10n?.rejectError ?? 'Error rejecting device'))),
          ),
          backgroundColor: success
              ? (approve ? AppTheme.primary : Colors.red)
              : Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    Widget pendingActionButton({
      required bool approve,
      required String label,
      required IconData icon,
    }) {
      final color = approve ? AppTheme.primary : Colors.red.shade600;
      return SizedBox(
        height: 38,
        child: ElevatedButton.icon(
          onPressed: isApprovalBusy
              ? null
              : () => runPendingAction(approve: approve),
          icon: isApprovalBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 18),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            disabledBackgroundColor: color.withOpacity(0.45),
            disabledForegroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );
    }

    Widget pendingApprovalPanel() {
      final l10n = AppLocalizations.of(context);
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final approveButton = pendingActionButton(
              approve: true,
              label: l10n?.approve ?? 'Approve',
              icon: Icons.check_circle,
            );
            final rejectButton = pendingActionButton(
              approve: false,
              label: l10n?.reject ?? 'Reject',
              icon: Icons.block,
            );

            if (constraints.maxWidth < 280) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  approveButton,
                  const SizedBox(height: 8),
                  rejectButton,
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: approveButton),
                const SizedBox(width: 8),
                Expanded(child: rejectButton),
              ],
            );
          },
        ),
      );
    }

    final showOperationProgress = provider.isDeviceUnderOperation(client);

    return Material(
      color: colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: isPendingApproval ? null : openDeviceDetail,
            splashColor: colorScheme.primary.withOpacity(0.1),
            highlightColor: colorScheme.primary.withOpacity(0.05),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.brightness == Brightness.dark
                        ? colorScheme.outline.withOpacity(0.2)
                        : Colors.grey.shade300,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Stack(
                    children: [
                      if (showPhase2Skeleton)
                        const _SkeletonBox(
                          width: 48,
                          height: 48,
                          borderRadius: 24,
                        )
                      else
                        CircleAvatar(
                          backgroundColor: isCurrentDevice
                              ? colorScheme.primary.withOpacity(0.2)
                              : typeColor.withOpacity(0.2),
                          child: Icon(
                            typeIcon,
                            color: isCurrentDevice
                                ? colorScheme.primary
                                : typeColor,
                            size: 24,
                          ),
                        ),
                      if (isCurrentDevice)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 12,
                            ),
                          ),
                        )
                      else if (client.isOnline == true)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: _buildOnlineStatusDot(client),
                        ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getDeviceDisplayName(client),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: isCurrentDevice
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (isStatic) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: colorScheme.primary,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.lock,
                                      size: 12,
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      'Static',
                                      style: TextStyle(
                                        color: colorScheme.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (isPendingApproval) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.orange,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.pending_actions,
                                      size: 12,
                                      color: Colors.orange,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      AppLocalizations.of(
                                            context,
                                          )?.pendingApproval ??
                                          'Pending Approval',
                                      style: const TextStyle(
                                        color: Colors.orange,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 4),
                        if (client.ipAddress != null)
                          Text(
                            client.macAddress != null
                                ? '${client.ipAddress} · ${client.macAddress}'
                                : 'IP: ${client.ipAddress}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.brightness == Brightness.dark
                                  ? colorScheme.onSurface.withOpacity(0.65)
                                  : Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (showPhase2Skeleton) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: const [
                              _SkeletonBox(width: 14, height: 10),
                              SizedBox(width: 3),
                              _SkeletonBox(width: 14, height: 10),
                              SizedBox(width: 3),
                              _SkeletonBox(width: 14, height: 10),
                              SizedBox(width: 8),
                              _SkeletonBox(width: 48, height: 10),
                            ],
                          ),
                        ] else if (client.signalStrength != null &&
                            client.signalStrength!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${client.signalStrength} dBm'
                            '${client.ssid != null && client.ssid!.isNotEmpty ? ' · ${client.ssid}' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.brightness == Brightness.dark
                                  ? colorScheme.onSurface.withOpacity(0.55)
                                  : Colors.grey.shade500,
                            ),
                          ),
                        ],
                        if (isPendingApproval) pendingApprovalPanel(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      ClientLiveTrafficBadge(client: client, fixedSlot: true),
                      if (!isPendingApproval) ...[
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: theme.brightness == Brightness.dark
                              ? colorScheme.onSurface.withOpacity(0.4)
                              : Colors.grey,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (showOperationProgress)
            const RepaintBoundary(
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppTheme.primary,
                backgroundColor: AppTheme.primaryTint,
              ),
            ),
        ],
      ),
    );
  }

  bool _isStaticDevice(ClientInfo client) {
    // 1. بررسی مستقیم isStaticLease
    if (client.isStaticLease == true) {
      return true;
    }

    // 2. اگر isStaticLease null است، از rawData  بررسی کن
    if (client.isStaticLease == null && client.rawData.isNotEmpty) {
      if (client.rawData.containsKey('dynamic')) {
        final dynamicValue = client.rawData['dynamic']
            ?.toString()
            .toLowerCase();
        if (dynamicValue == 'false' || dynamicValue == 'no') {
          return true; // Static
        }
      }
    }

    return false;
  }

  String _getDeviceDisplayName(ClientInfo client) {
    final l10n = AppLocalizations.of(context);
    return ClientDisplayName.displayLabel(
      client,
      devicePrefix: l10n?.device ?? 'Device',
      unknownLabel: l10n?.unknownDevice ?? 'Unknown Device',
    );
  }
}

class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    this.borderRadius = 4,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.3,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.grey.shade700
        : Colors.grey.shade300;

    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, child) {
        return Opacity(opacity: _opacity.value, child: child);
      },
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}
