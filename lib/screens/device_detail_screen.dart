import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/client_info.dart';
import '../providers/clients_provider.dart';
import '../services/mikrotik_service_manager.dart';

/// صفحه جزئیات دستگاه
class DeviceDetailScreen extends StatefulWidget {
  final ClientInfo device;
  final bool isCurrentDevice;
  final bool isBanned;

  const DeviceDetailScreen({
    super.key,
    required this.device,
    required this.isCurrentDevice,
    this.isBanned = false,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> with WidgetsBindingObserver {
  // ignore: unused_field
  bool _isLoading = false; // برای سایر عملیات (ban/unban/static)
  // Telegram 功能已禁用，以下字段保留用于将来的平台支持
  // ignore: unused_field
  Map<String, bool> _platformFilterStatus = {};
  // Map برای مدیریت loading state هر پلتفرم جداگانه
  Map<String, bool> _platformLoadingStatus = {};
  bool _isLoadingStatus = false; // برای جلوگیری از race condition
  bool _hasLoadedOnce = false; // برای بررسی اینکه آیا یک بار بارگذاری شده است
  bool _isDialogOpen = false; // برای جلوگیری از بررسی وضعیت در حین نمایش Dialog
  
  // برای ذخیره سرعت تنظیم شده (برای نمایش سریع)
  String? _currentSpeedLimit; // فرمت: "8M/7M"
  bool _isLoadingSpeed = false; // برای بارگذاری سرعت از RouterOS
  
  // برای ذخیره وضعیت Static/Dynamic Lease
  bool? _isStaticLease; // null = unknown, true = static, false = dynamic
  bool _isLoadingLeaseStatus = false; // برای بارگذاری وضعیت lease
  
  bool _isDisposed = false; // برای جلوگیری از setState بعد از dispose

  static const Color _primaryColor = Color(0xFF428B7C);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    print('═══════════════════════════════════════════════════════════');
    print('📱 [DEVICE_DETAIL] صفحه جزئیات دستگاه باز شد');
    print('📱 [DEVICE_DETAIL] IP: ${widget.device.ipAddress}');
    print('📱 [DEVICE_DETAIL] MAC: ${widget.device.macAddress}');
    print('📱 [DEVICE_DETAIL] نام: ${widget.device.hostName ?? widget.device.name ?? "نامشخص"}');
    print('📱 [DEVICE_DETAIL] مسدود شده: ${widget.isBanned}');
    print('═══════════════════════════════════════════════════════════');
    
    // Reset همه state ها برای اطمینان از بارگذاری مجدد
    _hasLoadedOnce = false;
    // Initialize platform filter status and loading status
    _platformFilterStatus = {
      'telegram': false,
      'youtube': false,
      'instagram': false,
      'facebook': false,
    };
    _platformLoadingStatus = {
      'telegram': false,
      'youtube': false,
      'instagram': false,
      'facebook': false,
    };
    
    // فوراً بارگذاری وضعیت Lease (Static/Dynamic) - اولویت اول
    if (widget.device.ipAddress != null && !widget.isBanned) {
      // فوراً شروع کن (بدون انتظار برای post frame callback)
      _loadLeaseStatus();
    }
    
    // فوراً از cache بارگذاری کن (اگر موجود است)
    if (widget.device.ipAddress != null && !widget.isBanned) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // ابتدا از cache استفاده کن (سریع)
        _loadPlatformFilterStatus(forceRefresh: false);
      });
    }
    
    // بارگذاری اطلاعات به صورت غیرهمزمان و بدون blocking کردن UI
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // سپس سایر داده‌ها را بارگذاری کن
      _loadAllData();
      _hasLoadedOnce = true;
      
      // بارگذاری سرعت از cache (سریع) و سپس از RouterOS (در پس‌زمینه)
      if (widget.device.ipAddress != null && !widget.isBanned) {
        // ابتدا از cache بارگذاری کن (سریع)
        _loadSpeedLimitFromCache();
        
        // سپس از RouterOS بارگذاری کن (در پس‌زمینه، بدون blocking)
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !_isDisposed) {
            _loadSpeedLimit();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _cancelAllPendingOperations();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  /// لغو همه عملیات در حال اجرا
  void _cancelAllPendingOperations() {
    _isDisposed = true;
    
    _isLoading = false;
    _isLoadingStatus = false;
    _platformLoadingStatus.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // وقتی اپلیکیشن از background به foreground برمی‌گردد، وضعیت را دوباره بررسی کن
    if (state == AppLifecycleState.resumed && _hasLoadedOnce && mounted) {
      // وضعیت را دوباره بررسی کن
    }
  }

  @override
  void didUpdateWidget(DeviceDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
      // اگر دستگاه تغییر کرد یا IP/MAC تغییر کرد، داده‌ها را دوباره بارگذاری کن
      if (        oldWidget.device.ipAddress != widget.device.ipAddress ||
          oldWidget.device.macAddress != widget.device.macAddress ||
          oldWidget.isBanned != widget.isBanned) {
        // Reset speed limit (cache را نگه داریم، فقط state را reset کن)
        _currentSpeedLimit = null;
        // Reset platform filter status and loading status
        _platformFilterStatus = {
          'telegram': false,
          'youtube': false,
          'instagram': false,
          'facebook': false,
        };
        _platformLoadingStatus = {
          'telegram': false,
          'youtube': false,
          'instagram': false,
          'facebook': false,
        };
        _loadAllData();
      } else {
        // حتی اگر دستگاه تغییر نکرده باشد، وضعیت Platform Filter و سرعت را دوباره بررسی کن
        // این برای اطمینان از به‌روز بودن وضعیت است
        // اما فقط اگر Dialog باز نیست
        if (widget.device.ipAddress != null && !widget.isBanned && !_isDialogOpen) {
          // بارگذاری سرعت از RouterOS
          _loadSpeedLimit();
          // فوراً از cache استفاده کن تا UI سریع به‌روزرسانی شود
          // سپس در پس‌زمینه از سرور به‌روزرسانی کن
          _loadPlatformFilterStatus(forceRefresh: false); // ابتدا از cache استفاده کن (سریع)
          
          // سپس در پس‌زمینه از سرور به‌روزرسانی کن (بدون blocking کردن UI)
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted && !_isDisposed) {
              _loadPlatformFilterStatus(forceRefresh: true);
            }
          });
        }
      }
  }

  /// بارگذاری همه داده‌ها به صورت همزمان و صبر برای تمام شدن
  Future<void> _loadAllData() async {
    if (_isDisposed || _isLoadingStatus) return;
    _isLoadingStatus = true;

    try {
      await _loadAllDataInternal();
    } catch (e) {
      // ignore errors
    }
  }

  Future<void> _loadAllDataInternal() async {
    if (_isDisposed) return;

    try {
      // بارگذاری داده‌ها
      await _loadPlatformFilterStatus(forceRefresh: false);
      
      if (_isDisposed) return;
      
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_isDisposed) {
          _loadPlatformFilterStatus(forceRefresh: true);
        }
      });
    } catch (e) {
      // ignore errors
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoadingStatus = false;
        });
      }
    }
  }

  /// بارگذاری وضعیت فیلترینگ شبکه‌های اجتماعی
  Future<void> _loadPlatformFilterStatus({bool forceRefresh = false}) async {
      if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      if (mounted && !_isDisposed) {
        setState(() {
          _platformFilterStatus['telegram'] = false;
          _platformFilterStatus['youtube'] = false;
          _platformFilterStatus['instagram'] = false;
          _platformFilterStatus['facebook'] = false;
        });
      }
      return;
    }

    try {
      await _loadPlatformFilterStatusInternal(forceRefresh);
    } catch (e) {
      if (!_isDisposed) {
      }
    }
  }

  Future<void> _loadPlatformFilterStatusInternal(bool forceRefresh) async {
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      return;
    }

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final status = await provider.getSocialMediaFilterStatus(widget.device.ipAddress!, forceRefresh: forceRefresh);
      
      if (_isDisposed || !mounted) return;
      
      final platforms = status['platforms'] as Map<String, dynamic>? ?? {};
      final newTelegramStatus = platforms['telegram'] == true;
      final newYoutubeStatus = platforms['youtube'] == true;
      final newInstagramStatus = platforms['instagram'] == true;
      final newFacebookStatus = platforms['facebook'] == true;
      
      if (mounted && !_isDisposed) {
        setState(() {
          _platformFilterStatus['telegram'] = newTelegramStatus;
          _platformFilterStatus['youtube'] = newYoutubeStatus;
          _platformFilterStatus['instagram'] = newInstagramStatus;
          _platformFilterStatus['facebook'] = newFacebookStatus;
        });
      }
    } catch (e) {
      if (_isDisposed) return;
      // در صورت خطا، سعی کن از cache استفاده کن (فقط اگر forceRefresh است)
      if (mounted && !_isDisposed && forceRefresh) {
        try {
          final provider = Provider.of<ClientsProvider>(context, listen: false);
          final cachedStatus = await provider.getSocialMediaFilterStatus(widget.device.ipAddress!, forceRefresh: false);
          
          if (_isDisposed || !mounted) return;
          
          final cachedPlatforms = cachedStatus['platforms'] as Map<String, dynamic>? ?? {};
          if (mounted && !_isDisposed) {
            setState(() {
              _platformFilterStatus['telegram'] = cachedPlatforms['telegram'] == true;
              _platformFilterStatus['youtube'] = cachedPlatforms['youtube'] == true;
              _platformFilterStatus['instagram'] = cachedPlatforms['instagram'] == true;
              _platformFilterStatus['facebook'] = cachedPlatforms['facebook'] == true;
            });
          }
        } catch (e2) {
          // ignore cache errors
        }
      }
    }
  }

  /// تغییر وضعیت فیلترینگ شبکه‌های اجتماعی
  Future<void> _togglePlatformFilter(String platform, String platformName) async {
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned || (_platformLoadingStatus[platform] ?? false)) {
      return;
    }

    final currentStatus = _platformFilterStatus[platform] ?? false;
    final newStatus = !currentStatus;

    if (!mounted || _isDisposed) return;

    setState(() {
      _platformLoadingStatus[platform] = true;
      _platformFilterStatus[platform] = newStatus;
    });

    try {
      await _togglePlatformFilterInternal(platform, platformName, currentStatus, newStatus);
    } catch (e) {
      if (!_isDisposed && mounted) {
        setState(() {
          _platformFilterStatus[platform] = currentStatus;
          _platformLoadingStatus[platform] = false;
        });
      }
    }
  }

  Future<void> _togglePlatformFilterInternal(String platform, String platformName, bool currentStatus, bool newStatus) async {
    if (_isDisposed) return;

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final result = await provider.togglePlatformFilter(
        widget.device.ipAddress!,
        platform,
        deviceMac: widget.device.macAddress,
        deviceName: widget.device.hostName ?? widget.device.name,
        enable: newStatus,
      );

      if (_isDisposed || !mounted) return;

      if (result['success'] == true) {
        setState(() {
          _platformLoadingStatus[platform] = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  newStatus ? Icons.check_circle : Icons.remove_circle,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    newStatus
                        ? 'فیلتر $platformName فعال شد'
                        : 'فیلتر $platformName غیرفعال شد',
                  ),
                ),
              ],
            ),
            backgroundColor: newStatus ? Colors.green : Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        // تازه‌سازی کامل داده‌های صفحه و رندر مجدد
        // ابتدا Provider را تازه‌سازی کن تا داده‌های کلی به‌روز شوند
        try {
          provider.refresh();
        } catch (e) {
          // ignore provider refresh errors
        }
        
        // سپس وضعیت فیلتر را از سرور دریافت کن
        _loadPlatformFilterStatus(forceRefresh: true).then((_) {
          if (mounted && !_isDisposed) {
            // رندر مجدد صفحه با داده‌های جدید
            setState(() {});
          }
        }).catchError((error) {
          // حتی اگر خطا رخ داد، سعی کن صفحه را رندر کن
          if (mounted && !_isDisposed) {
            setState(() {});
          }
        });
      } else {
        setState(() {
          _platformFilterStatus[platform] = currentStatus;
          _platformLoadingStatus[platform] = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'خطا: ${result['error'] ?? "خطا در تغییر وضعیت فیلتر"}',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        // حتی در صورت خطا، وضعیت را از سرور دریافت کن تا مطمئن شویم
        _loadPlatformFilterStatus(forceRefresh: true).then((_) {
          if (mounted && !_isDisposed) {
            setState(() {});
          }
        }).catchError((error) {
          // ignore refresh errors
        });
      }
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
      setState(() {
        _platformFilterStatus[platform] = currentStatus;
        _platformLoadingStatus[platform] = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('خطا: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      
      // حتی در صورت خطا، وضعیت را از سرور دریافت کن تا مطمئن شویم
      _loadPlatformFilterStatus(forceRefresh: true).then((_) {
        if (mounted && !_isDisposed) {
          setState(() {});
        }
      }).catchError((error) {
        // ignore refresh errors
      });
    }
  }

  Future<void> _setSpeedLimit() async {
    if (_isDisposed || widget.device.ipAddress == null) return;

    // اگر سرعت قبلاً تنظیم شده، آن را از state بگیر و به فرمت قابل نمایش تبدیل کن
    String? currentDownloadValue;
    String? currentUploadValue;
    String selectedDownloadUnit = 'M';
    String selectedUploadUnit = 'M';
    
    if (_currentSpeedLimit != null) {
      // فرمت: "8M/7M" -> download: 8M, upload: 7M
      final parts = _currentSpeedLimit!.split('/');
      if (parts.length == 2) {
        final uploadPart = parts[0].trim(); // 8M
        final downloadPart = parts[1].trim(); // 7M
        
        // استخراج عدد و واحد
        final uploadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(uploadPart);
        if (uploadMatch != null) {
          currentUploadValue = uploadMatch.group(1);
          selectedUploadUnit = (uploadMatch.group(2) ?? 'M').toUpperCase();
        }
        
        final downloadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(downloadPart);
        if (downloadMatch != null) {
          currentDownloadValue = downloadMatch.group(1);
          selectedDownloadUnit = (downloadMatch.group(2) ?? 'M').toUpperCase();
        }
      }
    }
    
    final downloadValueController = TextEditingController(text: currentDownloadValue ?? '');
    final uploadValueController = TextEditingController(text: currentUploadValue ?? '');
    final formKey = GlobalKey<FormState>();
    bool isSaving = false;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: MediaQuery.of(context).size.width * 0.95,
            constraints: const BoxConstraints(maxWidth: 600, minHeight: 400),
            padding: const EdgeInsets.all(28),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // هدر
                  Row(
                    children: [
                      const Icon(Icons.speed, color: _primaryColor, size: 32),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'تنظیم سرعت',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  // فرم
                  Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // فیلد سرعت دانلود
                        Row(
                          children: [
                            const Icon(Icons.download, color: Colors.blue, size: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'سرعت دانلود',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: TextFormField(
                                controller: downloadValueController,
                                decoration: InputDecoration(
                                  labelText: 'مقدار',
                                  hintText: '10',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  helperText: 'عدد را وارد کنید',
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                ),
                                textDirection: TextDirection.ltr,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontSize: 16),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'لطفاً عدد را وارد کنید';
                                  }
                                  final num = int.tryParse(value.trim());
                                  if (num == null || num <= 0) {
                                    return 'عدد باید بزرگتر از صفر باشد';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<String>(
                                value: selectedDownloadUnit,
                                decoration: InputDecoration(
                                  labelText: 'واحد',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                ),
                                style: const TextStyle(fontSize: 16),
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'M',
                                    child: Text('Mbps', style: TextStyle(color: Colors.blueGrey),),
                                  ),
                                  DropdownMenuItem(
                                    value: 'K', 
                                    child: Text('Kbps', style: TextStyle(color: Colors.blueGrey),),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(() {
                                      selectedDownloadUnit = value;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        // فیلد سرعت آپلود
                        Row(
                          children: [
                            const Icon(Icons.upload, color: Colors.green, size: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'سرعت آپلود',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: TextFormField(
                                controller: uploadValueController,
                                decoration: InputDecoration(
                                  labelText: 'مقدار',
                                  hintText: '10',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  helperText: 'عدد را وارد کنید',
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                ),
                                textDirection: TextDirection.ltr,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontSize: 16),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'لطفاً عدد را وارد کنید';
                                  }
                                  final num = int.tryParse(value.trim());
                                  if (num == null || num <= 0) {
                                    return 'عدد باید بزرگتر از صفر باشد';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<String>(
                                value: selectedUploadUnit,
                                decoration: InputDecoration(
                                  labelText: 'واحد',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                ),
                                style: const TextStyle(fontSize: 16),
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'M',
                                    child: Text('Mbps', style: TextStyle(color: Colors.blueGrey),),
                                  ),
                                  DropdownMenuItem(
                                    value: 'K',
                                    child: Text('Kbps', style: TextStyle(color: Colors.blueGrey),), 
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(() {
                                      selectedUploadUnit = value;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline, color: Colors.blue.shade700, size: 24),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'راهنمای واحدها:',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue.shade700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '• Mbps = مگابیت بر ثانیه\n• Kbps = کیلوبیت بر ثانیه',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.blue.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  // دکمه‌ها
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: isSaving ? null : () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                          minimumSize: const Size(100, 48),
                        ),
                        child: const Text(
                          'لغو',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: isSaving ? null : () async {
                          if (formKey.currentState!.validate()) {
                            setDialogState(() {
                              isSaving = true;
                            });
                            
                            final downloadValue = downloadValueController.text.trim();
                            final uploadValue = uploadValueController.text.trim();
                            
                            Navigator.pop(context, {
                              'download': '$downloadValue$selectedDownloadUnit',
                              'upload': '$uploadValue$selectedUploadUnit',
                            });
                          }
                        },
                        icon: isSaving 
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Icon(Icons.save),
                        label: Text(isSaving ? 'در حال ذخیره...' : 'ذخیره'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                          minimumSize: const Size(120, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // اگر کاربر داده‌ها را وارد کرد، سرعت را تنظیم کن
    if (result != null && !_isDisposed && mounted) {
      final download = result['download'] ?? '';
      final upload = result['upload'] ?? '';
      
      if (download.isNotEmpty && upload.isNotEmpty) {
        // فرمت: 4M/12M (آپلود/دانلود)
        final maxLimit = '$upload/$download';
        
        setState(() {
          _isLoading = true;
        });

        try {
          await _setSpeedLimitInternal(widget.device.ipAddress!, maxLimit);
        } catch (e) {
          if (!_isDisposed && mounted) {
            setState(() {
              _isLoading = false;
            });
          }
        }
      }
    }
  }

  Future<void> _setSpeedLimitInternal(String ipAddress, String maxLimit) async {
    // برای عملیات مهم مانند تنظیم سرعت، حتی اگر dispose شده باشیم،
    // باید عملیات را کامل کنیم (اما UI feedback را فقط اگر mounted باشیم نشان می‌دهیم)
    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final success = await provider.setClientSpeed(
        ipAddress,
        maxLimit,
      ).timeout(
        const Duration(seconds: 45), // افزایش timeout به 45 ثانیه
        onTimeout: () {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('زمان تنظیم سرعت به پایان رسید'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return false;
        },
      );

      // فقط اگر mounted باشیم، UI را به‌روزرسانی می‌کنیم
      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('سرعت با موفقیت تنظیم شد: $maxLimit'),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        // فوراً سرعت را در state ذخیره کن (برای نمایش سریع)
        setState(() {
          _currentSpeedLimit = maxLimit;
        });
        
        // ذخیره در cache برای بارگذاری بعدی
        _saveSpeedLimitToCache(maxLimit);
        
        // تازه‌سازی داده‌ها در پس‌زمینه
        try {
          provider.refresh();
          // در پس‌زمینه از RouterOS بارگذاری کن (برای تأیید)
          // 延迟一点时间，让 RouterOS 有时间创建 queue
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_isDisposed) {
              _loadSpeedLimit();
            }
          });
        } catch (e) {
          // ignore refresh errors
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('خطا: ${provider.errorMessage ?? "خطا در تنظیم سرعت"}'),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      // فقط اگر mounted باشیم، خطا را نمایش می‌دهیم
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('خطا: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      // فقط اگر mounted باشیم، loading state را به‌روزرسانی می‌کنیم
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// بارگذاری سرعت از cache (SharedPreferences)
  Future<void> _loadSpeedLimitFromCache() async {
    if (_isDisposed || widget.device.ipAddress == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'speed_limit_${widget.device.ipAddress}';
      final cachedSpeed = prefs.getString(cacheKey);
      
      if (cachedSpeed != null && cachedSpeed.isNotEmpty) {
        // 检查 cache 中的值是否有效（排除 "0K/0K" 或类似的值）
        final isValid = _isValidSpeedLimit(cachedSpeed);
        if (isValid) {
          print('✅ [LOAD_SPEED_CACHE] سرعت از cache بارگذاری شد: $cachedSpeed');
          if (mounted && !_isDisposed) {
            setState(() {
              _currentSpeedLimit = cachedSpeed;
            });
          }
        } else {
          print('⚠️ [LOAD_SPEED_CACHE] مقدار cache نامعتبر است (نادیده گرفته شد): $cachedSpeed');
          // 清除无效的 cache
          await prefs.remove(cacheKey);
        }
      }
    } catch (e) {
      print('⚠️ [LOAD_SPEED_CACHE] خطا در بارگذاری از cache: $e');
      // ignore errors
    }
  }

  /// بررسی اینکه سرعت معتبر است یا نه (مثلاً "0K/0K" نامعتبر است)
  bool _isValidSpeedLimit(String speedLimit) {
    if (speedLimit.isEmpty) return false;
    
    // 检查是否是 "0K/0K" 或类似的值
    if (speedLimit.toLowerCase().contains('0k/0k') || 
        speedLimit.toLowerCase().contains('0m/0m') ||
        speedLimit == '0/0') {
      return false;
    }
    
    // 检查格式是否正确 (应该包含 "/")
    if (!speedLimit.contains('/')) {
      return false;
    }
    
    return true;
  }

  /// ذخیره سرعت در cache (SharedPreferences)
  Future<void> _saveSpeedLimitToCache(String speedLimit) async {
    if (widget.device.ipAddress == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'speed_limit_${widget.device.ipAddress}';
      await prefs.setString(cacheKey, speedLimit);
      print('✅ [SAVE_SPEED_CACHE] سرعت در cache ذخیره شد: $speedLimit');
    } catch (e) {
      print('⚠️ [SAVE_SPEED_CACHE] خطا در ذخیره cache: $e');
      // ignore errors
    }
  }

  /// بارگذاری سرعت از RouterOS (در پس‌زمینه)
  Future<void> _loadSpeedLimit() async {
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      return;
    }

    if (_isLoadingSpeed) return; // جلوگیری از بارگذاری همزمان
    _isLoadingSpeed = true;

    try {
      // استفاده از MikroTikServiceManager برای دسترسی مستقیم
      final serviceManager = MikroTikServiceManager();
      if (serviceManager.service == null || !serviceManager.isConnected) {
        return;
      }
      
      // 增加 timeout 并添加日志
      print('🔧 [LOAD_SPEED] در حال بارگذاری سرعت برای IP: ${widget.device.ipAddress}');
      final speedInfo = await serviceManager.service!.getClientSpeed(widget.device.ipAddress!)
          .timeout(const Duration(seconds: 15), onTimeout: () {
            print('⚠️ [LOAD_SPEED] Timeout در بارگذاری سرعت برای IP: ${widget.device.ipAddress}');
            return null;
          });

      if (_isDisposed || !mounted) return;

      if (speedInfo != null && speedInfo['max_limit'] != null) {
        final maxLimit = speedInfo['max_limit'] as String;
        print('✅ [LOAD_SPEED] سرعت از RouterOS دریافت شد: $maxLimit');
        // maxLimit 从 getClientSpeed 已经转换好了（M/K 格式），直接使用
        // getClientSpeed 已经处理了所有格式转换（位格式 -> M/K 格式）
        // 所以这里不需要再次转换
        final formattedLimit = maxLimit;
        
        // فقط اگر از RouterOS 成功获取到值，才更新 state
        setState(() {
          _currentSpeedLimit = formattedLimit;
        });
        
        // ذخیره در cache برای بارگذاری بعدی
        _saveSpeedLimitToCache(formattedLimit);
      } else {
        // اگر queue وجود ندارد，但 _currentSpeedLimit 已经有值（刚刚设置的），不要清空它
        // 因为 queue 可能需要一点时间才能在 RouterOS 中完全可用
        // 只在页面首次加载时（_currentSpeedLimit 为 null）才清空
        if (_currentSpeedLimit == null) {
          setState(() {
            _currentSpeedLimit = null;
          });
        } else {
          // 如果已经有值，保留它（可能是刚刚设置的，RouterOS 还没完全创建）
          print('⚠️ [LOAD_SPEED] Queue 在 RouterOS 中还未找到،但保留本地值: $_currentSpeedLimit');
        }
      }
    } catch (e) {
      // 检查是否是超时错误
      final errorStr = e.toString().toLowerCase();
      final isTimeout = errorStr.contains('timeout') || 
                        errorStr.contains('خطا در دریافت سرعت');
      
      if (isTimeout) {
        print('⚠️ [LOAD_SPEED] Timeout در بارگذاری سرعت - استفاده از cache: ${_currentSpeedLimit ?? "ندارد"}');
      } else {
        print('⚠️ [LOAD_SPEED] خطا در بارگذاری سرعت: $e');
      }
      
      // ignore errors - این یک عملیات پس‌زمینه است
      // 如果已经有值，不要清空它（即使从 RouterOS 加载失败）
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoadingSpeed = false;
        });
      }
    }
  }

  Future<void> _banDevice() async {
    if (_isDisposed || widget.device.ipAddress == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مسدود کردن دستگاه'),
        content: Text(
          'آیا مطمئن هستید که می‌خواهید دستگاه ${widget.device.ipAddress} را مسدود کنید؟',
        ),
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
            child: const Text('مسدود کردن'),
          ),
        ],
      ),
    );

    if (confirmed == true && !_isDisposed) {
      if (!mounted) return;
      
      setState(() {
        _isLoading = true;
      });

      try {
        await _banDeviceInternal();
      } catch (e) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _banDeviceInternal() async {
    if (_isDisposed) return;

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final success = await provider.banClient(
        widget.device.ipAddress!,
        macAddress: widget.device.macAddress,
        hostname: widget.device.hostName,
        ssid: widget.device.ssid,
      );
      
      if (_isDisposed || !mounted) return;
      
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('دستگاه با موفقیت مسدود شد'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطا: ${provider.errorMessage ?? "خطا در مسدود کردن"}'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطا: $e'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _unbanDevice() async {
    if (_isDisposed || widget.device.ipAddress == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('رفع مسدودیت دستگاه'),
        content: Text(
          'آیا مطمئن هستید که می‌خواهید مسدودیت دستگاه ${widget.device.ipAddress} را بردارید؟',
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

    if (confirmed == true && !_isDisposed) {
      if (!mounted) return;
      
      setState(() {
        _isLoading = true;
      });

      try {
        await _unbanDeviceInternal();
      } catch (e) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _unbanDeviceInternal() async {
    if (_isDisposed) return;

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final success = await provider.unbanClient(
        widget.device.ipAddress!,
        macAddress: widget.device.macAddress,
        hostname: widget.device.hostName,
        ssid: widget.device.ssid,
      );
      
      if (_isDisposed || !mounted) return;
      
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('مسدودیت دستگاه با موفقیت برداشته شد'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطا: ${provider.errorMessage ?? "خطا در رفع مسدودیت"}'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطا: $e'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop) {
          _cancelAllPendingOperations();
          
          Future.microtask(() {
            try {
              final provider = Provider.of<ClientsProvider>(context, listen: false);
              provider.refresh();
            } catch (e) {
              // ignore refresh errors
            }
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('جزئیات دستگاه'),
          backgroundColor: _primaryColor,
          foregroundColor: Colors.white,
        ),
        body: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // هدر دستگاه
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    color: Colors.white,
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 40,
                              backgroundColor: widget.isCurrentDevice
                                  ? _primaryColor.withOpacity(0.2)
                                  : Colors.grey.shade200,
                              child: Icon(
                                _getDeviceIcon(widget.device.type),
                                size: 40,
                                color: widget.isCurrentDevice
                                    ? _primaryColor
                                    : Colors.grey.shade600,
                              ),
                            ),
                            if (widget.isCurrentDevice)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: _primaryColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.device.hostName ??
                              widget.device.user ??
                              widget.device.name ??
                              'نامشخص',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (widget.isCurrentDevice) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _primaryColor,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Text(
                              'شما',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // اطلاعات دستگاه
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'اطلاعات دستگاه',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _primaryColor,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildInfoRow('نوع', _getDeviceTypeLabel(widget.device.type)),
                        if (widget.device.ipAddress != null)
                          _buildInfoRow('آدرس IP', widget.device.ipAddress!),
                        if (widget.device.macAddress != null)
                          _buildInfoRow('آدرس MAC', widget.device.macAddress!),
                        if (widget.device.hostName != null)
                          _buildInfoRow('نام میزبان', widget.device.hostName!),
                        // نمایش وضعیت Lease (Static/Dynamic)
                        if (!widget.isBanned && (widget.device.ipAddress != null || widget.device.macAddress != null))
                          _buildLeaseStatusRow(),
                        if (widget.device.uptime != null)
                          _buildInfoRow('زمان اتصال', widget.device.uptime!),
                        if (widget.device.ssid != null)
                          _buildInfoRow('SSID', widget.device.ssid!),
                        if (widget.device.signalStrength != null)
                          _buildInfoRow(
                            'قدرت سیگنال',
                            widget.device.signalStrength!,
                          ),
                        // نمایش سرعت تنظیم شده (با نمایش بهتر)
                        if (_currentSpeedLimit != null && !widget.isBanned)
                          _buildSpeedLimitRow(_currentSpeedLimit!),
                        if (widget.isBanned)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.block, color: Colors.red, size: 20),
                                const SizedBox(width: 8),
                                const Text(
                                  'این دستگاه مسدود شده است',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // دکمه‌های عملیات
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'عملیات',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _primaryColor,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _setSpeedLimit,
                          icon: const Icon(Icons.speed), 
                          label: const Text('تنظیم سرعت' , style: TextStyle(fontSize: 20),),  
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (!widget.isBanned)
                          _buildStaticLeaseButton(),
                        const SizedBox(height: 12),
                        if (widget.isBanned)
                          ElevatedButton.icon(
                            onPressed: _unbanDevice,
                            icon: const Icon(Icons.lock_open),
                            label: const Text('رفع مسدودیت', style: TextStyle(fontSize: 20),),  
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          )
                        else
                          ElevatedButton.icon(
                            onPressed: _banDevice,
                            icon: const Icon(Icons.block),
                            label: const Text('مسدود کردن' , style: TextStyle(fontSize: 20),),  
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        // فیلتر شبکه‌های اجتماعی (انتخاب تکی هر پلتفرم)
                        if (!widget.isBanned)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.filter_alt,
                                      color: _primaryColor,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'فیلتر شبکه‌های اجتماعی',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: _primaryColor,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                ..._buildPlatformFilterToggles(),
                              ],
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


  List<Widget> _buildPlatformFilterToggles() {
    final platforms = [
      {'key': 'telegram', 'name': 'تلگرام', 'icon': Icons.telegram, 'color': Colors.blue},
      {'key': 'youtube', 'name': 'یوتیوب', 'icon': Icons.play_circle, 'color': Colors.red},
      {'key': 'instagram', 'name': 'اینستاگرام', 'icon': Icons.camera_alt, 'color': Color(0xFFE4405F)},
      {'key': 'facebook', 'name': 'فیسبوک', 'icon': Icons.facebook, 'color': Color(0xFF1877F2)},
    ];

    return platforms.map((platform) {
      final key = platform['key'] as String;
      final name = platform['name'] as String;
      final icon = platform['icon'] as IconData;
      final color = platform['color'] as Color;
      final isFiltered = _platformFilterStatus[key] ?? false;
      final isLoading = _platformLoadingStatus[key] ?? false;

      // محاسبه رنگ‌ها بر اساس loading state
      // در حالت loading: رنگ‌ها را کم‌رنگ‌تر کن (opacity کمتر)
      // در حالت عادی: رنگ‌ها را پررنگ کن
      final iconColor = isLoading 
          ? (isFiltered ? color.withOpacity(0.4) : Colors.grey.shade400)
          : (isFiltered ? color : Colors.grey);
      
      final titleColor = isLoading
          ? Colors.grey.shade500
          : (isFiltered ? color : Colors.black87);
      
      final containerColor = isLoading
          ? (isFiltered ? color.withOpacity(0.05) : Colors.grey.shade100)
          : (isFiltered ? color.withOpacity(0.1) : Colors.grey.shade50);
      
      final borderColor = isLoading
          ? (isFiltered ? color.withOpacity(0.3) : Colors.grey.shade300)
          : (isFiltered ? color : Colors.grey.shade300);

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: borderColor,
            width: isFiltered ? 2 : 1,
          ),
        ),
        child: ListTile(
          leading: Icon(icon, color: iconColor),
          title: Text(
            name,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: titleColor,
            ),
          ),
          trailing: Switch(
            value: isFiltered,
            onChanged: isLoading ? null : (value) {
              _togglePlatformFilter(key, name);
            },
            activeColor: isLoading ? color.withOpacity(0.5) : color,
          ),
          onTap: isLoading ? null : () {
            _togglePlatformFilter(key, name);
          },
        ),
      );
    }).toList();
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              textDirection: TextDirection.ltr,
            ),
          ),
        ],
      ),
    );
  }

  /// نمایش سرعت با فرمت کاربرپسند (با مشخص کردن دانلود و آپلود)
  Widget _buildSpeedLimitRow(String speedLimit) {
    // پارس کردن سرعت: "8M/7M" -> upload: 8M, download: 7M
    String uploadSpeed = '';
    String downloadSpeed = '';
    
    if (speedLimit.contains('/')) {
      final parts = speedLimit.split('/');
      if (parts.length == 2) {
        uploadSpeed = parts[0].trim();
        downloadSpeed = parts[1].trim();
      }
    } else {
      // اگر فقط یک مقدار است، برای هر دو استفاده می‌شود
      uploadSpeed = speedLimit;
      downloadSpeed = speedLimit;
    }
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              'حداکثر',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // آپلود
                Row(
                  children: [
                    const Icon(Icons.upload, color: Colors.green, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'آپلود: ',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    Text(
                      uploadSpeed,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.green,
                      ),
                      textDirection: TextDirection.ltr,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // دانلود
                Row(
                  children: [
                    const Icon(Icons.download, color: Colors.blue, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'دانلود: ',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    Text(
                      downloadSpeed,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue,
                      ),
                      textDirection: TextDirection.ltr,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getDeviceIcon(String type) {
    switch (type) {
      case 'wireless':
        return Icons.wifi;
      case 'dhcp':
        return Icons.lan;
      case 'hotspot':
        return Icons.router;
      case 'ppp':
        return Icons.phone;
      default:
        return Icons.device_unknown;
    }
  }

  String _getDeviceTypeLabel(String type) {
    switch (type) {
      case 'wireless':
        return 'Wireless';
      case 'dhcp':
        return 'DHCP';
      case 'hotspot':
        return 'Hotspot';
      case 'ppp':
        return 'PPP';
      default:
        return 'نامشخص';
    }
  }

  /// تبدیل Dynamic DHCP Lease به Static Lease
  Future<void> _makeStaticLease() async {
    print('═══════════════════════════════════════════════════════════');
    print('📱 [UI_STATIC] شروع فرآیند Static در UI');
    print('📱 [UI_STATIC] Device IP: ${widget.device.ipAddress ?? "N/A"}');
    print('📱 [UI_STATIC] Device MAC: ${widget.device.macAddress ?? "N/A"}');
    print('📱 [UI_STATIC] Device Hostname: ${widget.device.hostName ?? "N/A"}');
    print('📱 [UI_STATIC] Is Banned: ${widget.isBanned}');
    print('📱 [UI_STATIC] Is Disposed: $_isDisposed');
    
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      print('⚠️ [UI_STATIC] عملیات لغو شد - شرایط نامناسب');
      print('═══════════════════════════════════════════════════════════');
      return;
    }

    // نمایش Dialog تأیید
    print('💬 [UI_STATIC] نمایش Dialog تأیید...');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_clock, color: Colors.orange),
            SizedBox(width: 8),
            Text('Static کردن دستگاه'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'آیا می‌خواهید این دستگاه را به Static تبدیل کنید؟',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'مزایای Static Lease:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text('• IP address همیشه یکسان است'),
                  Text('• Hostname ثابت می‌ماند'),
                  Text('• شناسایی دستگاه آسان‌تر است'),
                  Text('• برای Ban بهتر است'),
                ],
              ),
            ),
          ],
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
            child: const Text('تأیید'),
          ),
        ],
      ),
    );

    print('💬 [UI_STATIC] نتیجه Dialog: ${confirm == true ? "تأیید" : "لغو"}');

    if (confirm != true || _isDisposed || !mounted) {
      print('⚠️ [UI_STATIC] عملیات لغو شد - کاربر تأیید نکرد یا صفحه dispose شده');
      print('═══════════════════════════════════════════════════════════');
      return;
    }

    print('🔄 [UI_STATIC] تنظیم loading state...');
    setState(() {
      _isLoading = true;
    });

    try {
      print('📞 [UI_STATIC] فراخوانی Provider.makeStaticLease()...');
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final result = await provider.makeStaticLease(
        macAddress: widget.device.macAddress,
        ipAddress: widget.device.ipAddress,
        hostname: widget.device.hostName,
        comment: 'Static via Flutter App',
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          print('⏱️ [UI_STATIC] Timeout در فراخوانی Provider (30 ثانیه)');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('زمان Static کردن به پایان رسید'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return {'success': false, 'error': 'Timeout'};
        },
      );

      print('📥 [UI_STATIC] نتیجه از Provider دریافت شد');
      print('   Success: ${result['success']}');
      print('   Message: ${result['message'] ?? result['error']}');

      if (!mounted || _isDisposed) {
        print('⚠️ [UI_STATIC] صفحه dispose شده - نمایش نتیجه لغو شد');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      if (result['success'] == true) {
        print('✅ [UI_STATIC] تبدیل موفق - نمایش پیام موفقیت');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(result['message'] ?? 'دستگاه با موفقیت Static شد'),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );

        // به‌روزرسانی وضعیت (فوراً)
        print('🔄 [UI_STATIC] به‌روزرسانی وضعیت UI...');
        if (mounted && !_isDisposed) {
          setState(() {
            _isStaticLease = true; // فوراً به‌روزرسانی کن
            _isLoadingLeaseStatus = false; // اگر در حال loading بود، متوقف کن
          });
        }

        // تازه‌سازی داده‌ها (در پس‌زمینه، بدون blocking کردن UI)
        print('🔄 [UI_STATIC] تازه‌سازی داده‌ها در پس‌زمینه...');
        Future.microtask(() async {
          try {
            await provider.refresh();
            // بعد از refresh، دوباره وضعیت lease را بررسی کن (برای اطمینان)
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_isDisposed) {
                _loadLeaseStatus();
              }
            });
            print('✅ [UI_STATIC] داده‌ها تازه‌سازی شدند');
          } catch (e) {
            print('⚠️ [UI_STATIC] خطا در تازه‌سازی داده‌ها: $e');
            // حتی اگر refresh خطا داد، وضعیت UI را حفظ کن
          }
        });
        print('✅ [UI_STATIC] فرآیند Static با موفقیت کامل شد');
        print('═══════════════════════════════════════════════════════════');
      } else {
        print('❌ [UI_STATIC] تبدیل ناموفق - نمایش پیام خطا');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(result['error'] ?? 'خطا در Static کردن دستگاه'),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        print('═══════════════════════════════════════════════════════════');
      }
    } catch (e, stackTrace) {
      print('❌ [UI_STATIC] خطای استثنا در فرآیند Static');
      print('   Error: $e');
      print('   Type: ${e.runtimeType}');
      print('   Stack: $stackTrace');
      
      if (!mounted || _isDisposed) {
        print('⚠️ [UI_STATIC] صفحه dispose شده - نمایش خطا لغو شد');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('خطا: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      print('═══════════════════════════════════════════════════════════');
    } finally {
      if (mounted && !_isDisposed) {
        print('🔄 [UI_STATIC] تنظیم loading state به false');
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// بارگذاری وضعیت Lease (Static/Dynamic)
  Future<void> _loadLeaseStatus() async {
    if (_isDisposed || widget.device.ipAddress == null && widget.device.macAddress == null) {
      return;
    }

    if (_isLoadingLeaseStatus) {
      return; // در حال بارگذاری است
    }

    setState(() {
      _isLoadingLeaseStatus = true;
    });

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final serviceManager = MikroTikServiceManager();
      
      if (!serviceManager.isConnected) {
        if (mounted && !_isDisposed) {
          setState(() {
            _isLoadingLeaseStatus = false;
            _isStaticLease = null;
          });
        }
        return;
      }

      // استفاده از service manager برای دریافت lease status
      final leaseStatus = await provider.getLeaseStatus(
        macAddress: widget.device.macAddress,
        ipAddress: widget.device.ipAddress,
      );

      if (mounted && !_isDisposed) {
        setState(() {
          _isStaticLease = leaseStatus;
          _isLoadingLeaseStatus = false;
        });
      }
    } catch (e) {
      print('⚠️ [DEVICE_DETAIL] خطا در بارگذاری وضعیت Lease: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoadingLeaseStatus = false;
          _isStaticLease = null;
        });
      }
    }
  }

  /// ساخت ردیف نمایش وضعیت Lease
  Widget _buildLeaseStatusRow() {
    if (_isLoadingLeaseStatus) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              'در حال بررسی وضعیت Lease...',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      );
    }

    if (_isStaticLease == null) {
      return const SizedBox.shrink(); // وضعیت نامشخص - نمایش نده
    }

    final isStatic = _isStaticLease == true;
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: isStatic ? Colors.orange.withOpacity(0.1) : Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isStatic ? Colors.orange.withOpacity(0.3) : Colors.blue.withOpacity(0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isStatic ? Icons.lock_clock : Icons.lock_open,
            color: isStatic ? Colors.orange : Colors.blue,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            isStatic ? 'Lease: Static (ثابت)' : 'Lease: Dynamic (پویا)',
            style: TextStyle(
              color: isStatic ? Colors.orange.shade700 : Colors.blue.shade700,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  /// ساخت دکمه Static/Dynamic بر اساس وضعیت
  Widget _buildStaticLeaseButton() {
    if (_isLoadingLeaseStatus) {
      return ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
        label: const Text('در حال بررسی...', style: TextStyle(fontSize: 20)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }

    final isStatic = _isStaticLease == true;
    
    return ElevatedButton.icon(
      onPressed: _isLoading ? null : (isStatic ? _makeDynamicLease : _makeStaticLease),
      icon: Icon(isStatic ? Icons.lock_open : Icons.lock_clock),
      label: Text(
        isStatic ? 'بازگشت به Dynamic' : 'Static کردن',
        style: const TextStyle(fontSize: 20),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: isStatic ? Colors.blue : Colors.orange,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  /// تبدیل Static Lease به Dynamic Lease
  Future<void> _makeDynamicLease() async {
    print('═══════════════════════════════════════════════════════════');
    print('📱 [UI_DYNAMIC] شروع فرآیند Dynamic در UI');
    print('📱 [UI_DYNAMIC] Device IP: ${widget.device.ipAddress ?? "N/A"}');
    print('📱 [UI_DYNAMIC] Device MAC: ${widget.device.macAddress ?? "N/A"}');
    
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      print('⚠️ [UI_DYNAMIC] عملیات لغو شد - شرایط نامناسب');
      print('═══════════════════════════════════════════════════════════');
      return;
    }

    // نمایش Dialog تأیید
    print('💬 [UI_DYNAMIC] نمایش Dialog تأیید...');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_open, color: Colors.blue),
            SizedBox(width: 8),
            Text('بازگشت به Dynamic'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'آیا می‌خواهید این دستگاه را به Dynamic تبدیل کنید؟',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              'توجه: با تبدیل به Dynamic، IP address ممکن است تغییر کند.',
              style: TextStyle(fontSize: 14, color: Colors.orange),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text('تأیید'),
          ),
        ],
      ),
    );

    print('💬 [UI_DYNAMIC] نتیجه Dialog: ${confirm == true ? "تأیید" : "لغو"}');

    if (confirm != true || _isDisposed || !mounted) {
      print('⚠️ [UI_DYNAMIC] عملیات لغو شد');
      print('═══════════════════════════════════════════════════════════');
      return;
    }

    print('🔄 [UI_DYNAMIC] تنظیم loading state...');
    setState(() {
      _isLoading = true;
    });

    try {
      print('📞 [UI_DYNAMIC] فراخوانی Provider.makeDynamicLease()...');
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      
      if (!provider.isConnected) {
        throw Exception('اتصال برقرار نشده');
      }

      final result = await provider.makeDynamicLease(
        macAddress: widget.device.macAddress,
        ipAddress: widget.device.ipAddress,
      ).timeout(
        const Duration(seconds: 35), // کمی بیشتر از provider timeout
        onTimeout: () {
          print('⏱️ [UI_DYNAMIC] Timeout در فراخوانی Provider (35 ثانیه)');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('زمان تبدیل به Dynamic به پایان رسید'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          throw TimeoutException('Timeout', const Duration(seconds: 35));
        },
      );

      print('📥 [UI_DYNAMIC] نتیجه از Provider دریافت شد');
      print('   Success: ${result['success']}');
      print('   Message: ${result['message'] ?? result['error']}');

      if (!mounted || _isDisposed) {
        print('⚠️ [UI_DYNAMIC] صفحه dispose شده');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      if (result['success'] == true) {
        print('✅ [UI_DYNAMIC] تبدیل موفق');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(result['message'] ?? 'دستگاه با موفقیت Dynamic شد'),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );

        // به‌روزرسانی وضعیت
        setState(() {
          _isStaticLease = false;
        });

        // به‌روزرسانی وضعیت (فوراً)
        print('🔄 [UI_DYNAMIC] به‌روزرسانی وضعیت UI...');
        if (mounted && !_isDisposed) {
          setState(() {
            _isStaticLease = false; // فوراً به‌روزرسانی کن
            _isLoadingLeaseStatus = false; // اگر در حال loading بود، متوقف کن
          });
        }

        // تازه‌سازی داده‌ها (در پس‌زمینه، بدون blocking کردن UI)
        print('🔄 [UI_DYNAMIC] تازه‌سازی داده‌ها در پس‌زمینه...');
        Future.microtask(() async {
          try {
            await provider.refresh();
            // بعد از refresh، دوباره وضعیت lease را بررسی کن (برای اطمینان)
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_isDisposed) {
                _loadLeaseStatus();
              }
            });
            print('✅ [UI_DYNAMIC] داده‌ها تازه‌سازی شدند');
          } catch (e) {
            print('⚠️ [UI_DYNAMIC] خطا در تازه‌سازی داده‌ها: $e');
            // حتی اگر refresh خطا داد، وضعیت UI را حفظ کن
          }
        });
        print('✅ [UI_DYNAMIC] فرآیند Dynamic با موفقیت کامل شد');
        print('═══════════════════════════════════════════════════════════');
      } else {
        print('❌ [UI_DYNAMIC] تبدیل ناموفق');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(result['message'] ?? 'خطا در Dynamic کردن دستگاه'),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        print('═══════════════════════════════════════════════════════════');
      }
    } catch (e, stackTrace) {
      print('❌ [UI_DYNAMIC] خطای استثنا در فرآیند Dynamic');
      print('   Error: $e');
      print('   Type: ${e.runtimeType}');
      print('   Stack: $stackTrace');
      
      if (!mounted || _isDisposed) {
        print('⚠️ [UI_DYNAMIC] صفحه dispose شده');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('خطا: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      print('═══════════════════════════════════════════════════════════');
    } finally {
      if (mounted && !_isDisposed) {
        print('🔄 [UI_DYNAMIC] تنظیم loading state به false');
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

}


