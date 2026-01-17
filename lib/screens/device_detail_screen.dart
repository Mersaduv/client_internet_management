import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/client_info.dart';
import '../services/mikrotik_service_manager.dart';
import '../providers/clients_provider.dart';

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
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  bool _isLoading = false; // برای سایر عملیات (سرعت، static، etc.)
  String? _speedLimit;
  // Telegram 功能已禁用，以下字段保留用于将来的平台支持
  // ignore: unused_field
  Map<String, bool> _platformFilterStatus = {};
  // Map برای مدیریت loading state هر پلتفرم جداگانه
  Map<String, bool> _platformLoadingStatus = {};
  bool _isLoadingStatus = false; // برای جلوگیری از race condition
  bool? _isStatic;
  bool _isLoadingStatic = false;
  bool _hasLoadedOnce = false; // برای بررسی اینکه آیا یک بار بارگذاری شده است
  bool _isDialogOpen = false; // برای جلوگیری از بررسی وضعیت در حین نمایش Dialog
  
  // برای ذخیره Future های در حال اجرا جهت cancel کردن
  final List<Future> _pendingFutures = [];
  bool _isDisposed = false; // برای جلوگیری از setState بعد از dispose

  static const Color _primaryColor = Color(0xFF428B7C);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reset همه state ها برای اطمینان از بارگذاری مجدد
    _isStatic = null;
    _isLoadingStatic = false;
    _speedLimit = null;
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
    
    // فوراً از cache بارگذاری کن (اگر موجود است)
    if (widget.device.ipAddress != null && !widget.isBanned) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // ابتدا از cache استفاده کن (سریع)
        _loadPlatformFilterStatus(forceRefresh: false);
      });
    }
    
    // بارگذاری اطلاعات به صورت غیرهمزمان و بدون blocking کردن UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAllData();
      _hasLoadedOnce = true;
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
    _pendingFutures.clear();
    
    _isLoading = false;
    _isLoadingStatus = false;
    _isLoadingStatic = false;
    _platformLoadingStatus.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // وقتی اپلیکیشن از background به foreground برمی‌گردد، وضعیت را دوباره بررسی کن
    if (state == AppLifecycleState.resumed && _hasLoadedOnce && mounted) {
      _checkStaticStatus();
    }
  }

  @override
  void didUpdateWidget(DeviceDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // اگر دستگاه تغییر کرد یا IP/MAC تغییر کرد، داده‌ها را دوباره بارگذاری کن
    if (oldWidget.device.ipAddress != widget.device.ipAddress ||
        oldWidget.device.macAddress != widget.device.macAddress ||
        oldWidget.isBanned != widget.isBanned) {
      _isStatic = null;
      _isLoadingStatic = false;
      _speedLimit = null;
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
      // حتی اگر دستگاه تغییر نکرده باشد، وضعیت Static و Platform Filter را دوباره بررسی کن
      // این برای اطمینان از به‌روز بودن وضعیت است
      // اما فقط اگر Dialog باز نیست
      if (widget.device.ipAddress != null && !widget.isBanned && !_isDialogOpen) {
        _checkStaticStatus();
        // فوراً از cache استفاده کن تا UI سریع به‌روزرسانی شود
        // سپس در پس‌زمینه از سرور به‌روزرسانی کن
        _loadPlatformFilterStatus(forceRefresh: false); // ابتدا از cache استفاده کن (سریع)
        
        // سپس در پس‌زمینه از سرور به‌روزرسانی کن (بدون blocking کردن UI)
        final delayedFuture = Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !_isDisposed) {
            _loadPlatformFilterStatus(forceRefresh: true);
          }
        });
        _pendingFutures.add(delayedFuture);
      }
    }
  }

  /// بارگذاری همه داده‌ها به صورت همزمان و صبر برای تمام شدن
  Future<void> _loadAllData() async {
    if (_isDisposed || _isLoadingStatus) return;
    _isLoadingStatus = true;

    final loadAllFuture = _loadAllDataInternal();
    _pendingFutures.add(loadAllFuture);
    
    try {
      await loadAllFuture;
    } catch (e) {
      if (!_isDisposed) {
        print('[STATIC] _loadAllData: خطا در بارگذاری داده‌ها: $e');
      }
    }
  }

  Future<void> _loadAllDataInternal() async {
    if (_isDisposed) return;

    try {
      await Future.wait([
        _loadSpeedLimit(),
        _checkStaticStatus(),
        _loadPlatformFilterStatus(forceRefresh: false),
      ]);
      
      if (_isDisposed) return;
      
      final delayedFuture = Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_isDisposed) {
          _loadPlatformFilterStatus(forceRefresh: true);
        }
      });
      _pendingFutures.add(delayedFuture);
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

    final loadFuture = _loadPlatformFilterStatusInternal(forceRefresh);
    _pendingFutures.add(loadFuture);
    
    try {
      await loadFuture;
    } catch (e) {
      if (!_isDisposed) {
        print('[Platform Filter] خطا در بارگذاری وضعیت: $e');
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

    final toggleFuture = _togglePlatformFilterInternal(platform, platformName, currentStatus, newStatus);
    _pendingFutures.add(toggleFuture);
    
    try {
      await toggleFuture;
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
        
        final refreshFuture = _loadPlatformFilterStatus(forceRefresh: true);
        _pendingFutures.add(refreshFuture);
        refreshFuture.catchError((error) {
          // ignore refresh errors
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
    }
  }

  Future<void> _loadSpeedLimit() async {
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned) {
      return;
    }

    try {
      final service = _serviceManager.service;
      if (service == null || !_serviceManager.isConnected) {
        if (mounted && !_isDisposed) {
          setState(() {
            _speedLimit = 'N/A';
          });
        }
        return;
      }

      final queues = await service.getClientSpeed(widget.device.ipAddress!).timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      
      if (_isDisposed || !mounted) return;
      
      setState(() {
        _speedLimit = queues?['max_limit'] ?? 'N/A';
      });
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
      setState(() {
        _speedLimit = 'N/A';
      });
    }
  }

  Future<void> _checkStaticStatus() async {
    if (_isDisposed || _isDialogOpen) {
      return;
    }
    
    if (widget.device.ipAddress == null || widget.isBanned) {
      if (mounted && !_isDisposed) {
        setState(() {
          _isStatic = null;
          _isLoadingStatic = false;
        });
      }
      return;
    }

    if (_isLoadingStatic) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (_isDisposed || _isLoadingStatic) {
        return;
      }
    }

    _isLoadingStatic = true;
    final checkFuture = _checkStaticStatusInternal();
    _pendingFutures.add(checkFuture);
    
    try {
      await checkFuture;
    } catch (e) {
      if (!_isDisposed && mounted) {
        setState(() {
          _isStatic = null;
          _isLoadingStatic = false;
        });
      }
    }
  }

  Future<void> _checkStaticStatusInternal() async {
    if (_isDisposed) return;

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final isStatic = await provider.isDeviceStatic(
        widget.device.ipAddress,
        widget.device.macAddress,
        hostname: widget.device.hostName ?? widget.device.name,
      );
      
      if (_isDisposed || !mounted) return;
      
      setState(() {
        _isStatic = isStatic;
        _isLoadingStatic = false;
      });
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
      setState(() {
        _isStatic = null;
        _isLoadingStatic = false;
      });
    }
  }

  Future<void> _toggleStaticStatus() async {
    if (_isDisposed || widget.device.ipAddress == null || widget.isBanned || _isLoading) {
      return;
    }

    if (_isDisposed || !mounted) return;
    
    final isCurrentlyStatic = _isStatic == true;
    
    setState(() {
      _isDialogOpen = true;
    });

    final actionText = isCurrentlyStatic ? 'تبدیل به غیر Static' : 'تبدیل به Static';
    final message = isCurrentlyStatic
        ? 'آیا مطمئن هستید که می‌خواهید دستگاه ${widget.device.ipAddress} را به غیر Static تبدیل کنید؟\n\n'
            'بعد از تبدیل به غیر Static:\n'
            '• IP دستگاه ممکن است تغییر کند\n'
            '• دستگاه به صورت Dynamic شناسایی می‌شود'
        : 'آیا مطمئن هستید که می‌خواهید دستگاه ${widget.device.ipAddress} را به Static تبدیل کنید؟\n\n'
            'بعد از تبدیل به Static:\n'
            '• IP دستگاه ثابت می‌ماند\n'
            '• MAC Address ثابت می‌ماند\n'
            '• دستگاه همیشه با همان IP شناسایی می‌شود';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(actionText),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isCurrentlyStatic ? Colors.orange : _primaryColor,
              foregroundColor: Colors.white,
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );

    if (mounted && !_isDisposed) {
      setState(() {
        _isDialogOpen = false;
      });
    }

    if (confirmed == true && !_isDisposed) {
      if (!mounted) return;
      
      setState(() {
        _isLoading = true;
        _isDialogOpen = true;
      });

      final toggleFuture = _toggleStaticStatusInternal(isCurrentlyStatic);
      _pendingFutures.add(toggleFuture);
      
      try {
        await toggleFuture;
      } catch (e) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isLoading = false;
            _isDialogOpen = false;
          });
        }
      }
    }
  }

  Future<void> _toggleStaticStatusInternal(bool isCurrentlyStatic) async {
    if (_isDisposed) return;

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final success = await provider.setDeviceStaticStatus(
        widget.device.ipAddress!,
        widget.device.macAddress,
        hostname: widget.device.hostName ?? widget.device.name,
        isStatic: !isCurrentlyStatic,
      );

      if (_isDisposed || !mounted) return;

      if (success) {
        setState(() {
          _isStatic = !isCurrentlyStatic;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isCurrentlyStatic
                        ? 'دستگاه با موفقیت به غیر Static تبدیل شد'
                        : 'دستگاه با موفقیت به Static تبدیل شد',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        await Future.delayed(const Duration(milliseconds: 1000));
        
        if (_isDisposed || !mounted) return;
        
        setState(() {
          _isDialogOpen = false;
        });
        
        final checkFuture = _checkStaticStatus();
        _pendingFutures.add(checkFuture);
        await checkFuture;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'خطا: ${provider.errorMessage ?? "خطا در تغییر وضعیت Static"}',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (_isDisposed || !mounted) return;
      
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
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoading = false;
          _isDialogOpen = false;
        });
      }
    }
  }

  Future<void> _setSpeedLimit() async {
    if (_isDisposed || widget.device.ipAddress == null) return;

    // ابتدا سرعت فعلی را از Simple Queues دریافت کن
    String? currentSpeedLimit;
    try {
      // دریافت لیست Simple Queues و پیدا کردن queue مربوط به این دستگاه
      final service = _serviceManager.service;
      if (service != null && _serviceManager.isConnected) {
        final speed = await service.getClientSpeed(widget.device.ipAddress!);
        currentSpeedLimit = speed?['max_limit'];
        
        // اگر با IP پیدا نشد، با MAC address امتحان کن
        if ((currentSpeedLimit == null || currentSpeedLimit == 'N/A') && widget.device.macAddress != null) {
          final speedByMac = await service.getClientSpeed(widget.device.macAddress!);
          currentSpeedLimit = speedByMac?['max_limit'];
        }
      }
    } catch (e) {
      // اگر خطا رخ داد، از مقدار قبلی استفاده کن
      if (_speedLimit != null && _speedLimit != 'N/A') {
        currentSpeedLimit = _speedLimit;
      }
    }

    // استخراج سرعت فعلی برای نمایش در فیلدها
    String currentDownloadValue = '';
    String currentUploadValue = '';
    String currentDownloadUnit = 'M';
    String currentUploadUnit = 'M';
    
    if (currentSpeedLimit != null && currentSpeedLimit != 'N/A' && currentSpeedLimit.isNotEmpty) {
      // فرمت MikroTik: upload/download (مثال: 10M/10M)
      final parts = currentSpeedLimit.split('/');
      if (parts.length == 2) {
        final uploadPart = parts[0].trim();
        final downloadPart = parts[1].trim();
        
        // استخراج عدد و واحد از آپلود
        final uploadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(uploadPart);
        if (uploadMatch != null) {
          currentUploadValue = uploadMatch.group(1) ?? '';
          final unit = uploadMatch.group(2) ?? '';
          currentUploadUnit = unit.isEmpty ? 'M' : unit.toUpperCase();
        }
        
        // استخراج عدد و واحد از دانلود
        final downloadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(downloadPart);
        if (downloadMatch != null) {
          currentDownloadValue = downloadMatch.group(1) ?? '';
          final unit = downloadMatch.group(2) ?? '';
          currentDownloadUnit = unit.isEmpty ? 'M' : unit.toUpperCase();
        }
      } else if (parts.length == 1) {
        // اگر فقط یک مقدار وجود دارد (فرمت قدیمی)
        final singleMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(parts[0].trim());
        if (singleMatch != null) {
          final value = singleMatch.group(1) ?? '';
          final unit = singleMatch.group(2) ?? '';
          final unitUpper = unit.isEmpty ? 'M' : unit.toUpperCase();
          currentDownloadValue = value;
          currentUploadValue = value;
          currentDownloadUnit = unitUpper;
          currentUploadUnit = unitUpper;
        }
      }
    }

    final downloadValueController = TextEditingController(text: currentDownloadValue);
    final uploadValueController = TextEditingController(text: currentUploadValue);
    String selectedDownloadUnit = currentDownloadUnit;
    String selectedUploadUnit = currentUploadUnit;
    final formKey = GlobalKey<FormState>();

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
                        onPressed: () => Navigator.pop(context),
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
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            final downloadValue = downloadValueController.text.trim();
                            final uploadValue = uploadValueController.text.trim();
                            
                            Navigator.pop(context, {
                              'download': '$downloadValue$selectedDownloadUnit',
                              'upload': '$uploadValue$selectedUploadUnit',
                            });
                          }
                        },
                        icon: const Icon(Icons.save),
                        label: const Text('ذخیره'),
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

    if (result != null && !_isDisposed) {
      if (!mounted) return;
      
      setState(() {
        _isLoading = true;
      });

      final setSpeedFuture = _setSpeedLimitInternal(result);
      _pendingFutures.add(setSpeedFuture);
      
      try {
        await setSpeedFuture;
      } catch (e) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _setSpeedLimitInternal(Map<String, String> result) async {
    if (_isDisposed) return;

    try {
      final speedLimit = '${result['upload']}/${result['download']}';
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      final success = await provider.setClientSpeed(
        widget.device.ipAddress!,
        speedLimit,
      );
      
      if (_isDisposed || !mounted) return;
      
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'سرعت تنظیم شد: دانلود ${result['download']} - آپلود ${result['upload']}',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        final loadFuture = _loadSpeedLimit();
        _pendingFutures.add(loadFuture);
        await loadFuture;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'خطا: ${provider.errorMessage ?? "خطا در تنظیم سرعت"}',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
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
      setState(() {
        _isLoading = false;
      });
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

      final banFuture = _banDeviceInternal();
      _pendingFutures.add(banFuture);
      
      try {
        await banFuture;
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

      final unbanFuture = _unbanDeviceInternal();
      _pendingFutures.add(unbanFuture);
      
      try {
        await unbanFuture;
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
    // هر بار که build فراخوانی می‌شود، اگر وضعیت Static null است و شرایط مناسب است، بررسی کن
    // این برای حالتی است که کاربر از صفحه خارج شده و دوباره وارد شده است
    // اما فقط اگر Dialog باز نیست
    if (_isStatic == null && !_isLoadingStatic && !_isLoadingStatus && !_isDialogOpen &&
        widget.device.ipAddress != null && !widget.isBanned) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isStatic == null && !_isLoadingStatic && !_isDialogOpen) {
          _checkStaticStatus();
        }
      });
    }

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
                        if (_isStatic != null && !widget.isBanned)
                          _buildInfoRow(
                            'وضعیت IP',
                            _isStatic == true
                                ? 'Static (ثابت)'
                                : 'Dynamic (پویا)',
                          ),
                        if (widget.device.hostName != null)
                          _buildInfoRow('نام میزبان', widget.device.hostName!),
                        if (widget.device.uptime != null)
                          _buildInfoRow('زمان اتصال', widget.device.uptime!),
                        if (widget.device.ssid != null)
                          _buildInfoRow('SSID', widget.device.ssid!),
                        if (widget.device.signalStrength != null)
                          _buildInfoRow(
                            'قدرت سیگنال',
                            widget.device.signalStrength!,
                          ),
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
                          )
                        else ...[
                          if (_speedLimit != null && _speedLimit != 'N/A')
                            _buildSpeedInfoRow(_speedLimit!),
                        ],
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
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _toggleStaticStatus,
                            icon: Icon(_isStatic == true ? Icons.lock : Icons.lock_open),
                            label: Text(
                              _isStatic == true ? 'تبدیل به غیر Static' : 'تبدیل به Static',
                              style: const TextStyle(fontSize: 20),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isStatic == true ? Colors.orange : Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              disabledBackgroundColor: Colors.grey,
                            ),
                          ),
                        if (!widget.isBanned) const SizedBox(height: 12),
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

  Widget _buildSpeedInfoRow(String speedLimit) {
    // تجزیه سرعت به آپلود و دانلود
    final parts = speedLimit.split('/');
    String uploadSpeed = '';
    String downloadSpeed = '';
    
    if (parts.length == 2) {
      uploadSpeed = parts[0].trim();
      downloadSpeed = parts[1].trim();
    } else {
      uploadSpeed = speedLimit;
      downloadSpeed = speedLimit;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  'حداکثر سرعت',
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
                    Row(
                      children: [
                        const Icon(Icons.download, size: 16, color: Colors.blue),
                        const SizedBox(width: 4),
                        Text(
                          '$downloadSpeed',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.blue,
                          ),
                          textDirection: TextDirection.ltr,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.upload, size: 16, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(
                          '$uploadSpeed',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.green,
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
        ],
      ),
    );
  }
}


