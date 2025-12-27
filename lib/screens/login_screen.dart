import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/mikrotik_connection.dart';
import '../services/mikrotik_service_manager.dart';
import '../services/settings_service.dart';

/// صفحه ورود مدرن و حرفه‌ای
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isConnecting = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  final FocusNode _usernameFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final SettingsService _settingsService = SettingsService();

  // رنگ تم سبز
  static const Color _primaryColor = Color(0xFF428B7C);

  @override
  void initState() {
    super.initState();
    _checkLoginExpiration();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  /// بررسی انقضای لاگین
  Future<void> _checkLoginExpiration() async {
    final isExpired = await _settingsService.isLoginExpired();
    if (isExpired && mounted) {
      // اگر لاگین منقضی شده باشد، زمان لاگین را پاک کن
      await _settingsService.clearLoginTimestamp();
    }
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // مخفی کردن کیبورد
    FocusScope.of(context).unfocus();

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      // دریافت تنظیمات از SettingsService
      final settings = await _settingsService.getAllSettings();
      
      // ایجاد اتصال با اطلاعات وارد شده و تنظیمات ذخیره شده
      final connection = MikroTikConnection(
        host: settings['host'] as String,
        port: settings['port'] as int,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        useSsl: settings['useSsl'] as bool,
      );

      // استفاده از Service Manager برای نگه‌داری اتصال
      final serviceManager = MikroTikServiceManager();
      final success = await serviceManager.connect(connection);

      setState(() {
        _isConnecting = false;
      });

      if (success) {
        // ذخیره زمان لاگین
        await _settingsService.setLoginTimestamp();
        
        // اتصال موفق - مقداردهی اولیه Provider و انتقال به صفحه اصلی
        if (mounted) {
          // Provider در initState صفحه اصلی initialize می‌شود
          Navigator.of(context).pushReplacementNamed('/home');
        }
      } else {
        setState(() {
          _errorMessage = 'نام کاربری یا رمز عبور اشتباه است';
        });
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _errorMessage = 'خطا در اتصال: ${e.toString().replaceAll('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),

                  // لوگو (بزرگ‌تر و کمی پایین‌تر تا به فیلدها نزدیک شود)
                  Center(
                    child: Image.asset(
                      'assets/images/logos/logo.png',
                      height: 230,
                      width: 230,
                      errorBuilder: (context, error, stackTrace) {
                        // اگر لوگو پیدا نشد، از آیکون استفاده کن
                        return Container(
                          width: 230,
                          height: 230,
                          decoration: BoxDecoration(
                            color: _primaryColor.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.router,
                            size: 90,
                            color: _primaryColor,
                          ),
                        );
                      },
                    ),
                  ),
                  // const SizedBox(height: 24),

                  // عنوان
                  const SizedBox(height: 8),
                  Text(
                    'لطفاً اطلاعات روتر خود را وارد کنید',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // فیلد نام کاربری
                  TextFormField(
                    controller: _usernameController,
                    focusNode: _usernameFocusNode,
                    decoration: InputDecoration(
                      labelText: 'نام کاربری',
                      hintText: 'username',
                      prefixIcon: const Icon(
                        Icons.person_outline,
                        color: _primaryColor,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: _primaryColor,
                          width: 2,
                        ),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      labelStyle: TextStyle(color: Colors.grey.shade700),
                      hintStyle: TextStyle(color: Colors.grey.shade400),
                    ),
                    textDirection: TextDirection.ltr,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) {
                      FocusScope.of(context).requestFocus(_passwordFocusNode);
                    },
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'لطفاً نام کاربری را وارد کنید';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),

                  // فیلد رمز عبور
                  TextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocusNode,
                    decoration: InputDecoration(
                      labelText: 'رمز عبور',
                      hintText: 'رمز عبور خود را وارد کنید',
                      prefixIcon: const Icon(
                        Icons.lock_outline,
                        color: _primaryColor,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: Colors.grey.shade600,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: _primaryColor,
                          width: 2,
                        ),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      labelStyle: TextStyle(color: Colors.grey.shade700),
                      hintStyle: TextStyle(color: Colors.grey.shade400),
                    ),
                    obscureText: _obscurePassword,
                    textDirection: TextDirection.ltr,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _handleLogin(),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'لطفاً رمز عبور را وارد کنید';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),

                  // دکمه ورود
                  Container(
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryColor.withOpacity(0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: _isConnecting ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: _isConnecting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.login, size: 22),
                                SizedBox(width: 12),
                                Text(
                                  'ورود',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),

                  // نمایش خطا
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.red.shade200,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: Colors.red.shade700,
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
