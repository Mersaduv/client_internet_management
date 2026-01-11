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
  bool _isLoading = false;
  String? _speedLimit;
  // Telegram 功能已禁用，以下字段保留用于将来的平台支持
  // ignore: unused_field
  Map<String, bool> _platformFilterStatus = {};
  bool _isLoadingStatus = false; // برای جلوگیری از race condition
  bool? _isStatic;
  bool _isLoadingStatic = false;
  bool _hasLoadedOnce = false; // برای بررسی اینکه آیا یک بار بارگذاری شده است
  bool _isDialogOpen = false; // برای جلوگیری از بررسی وضعیت در حین نمایش Dialog

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
    // بارگذاری اطلاعات به صورت غیرهمزمان و بدون blocking کردن UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAllData();
      _hasLoadedOnce = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      _loadAllData();
    } else {
      // حتی اگر دستگاه تغییر نکرده باشد، وضعیت Static را دوباره بررسی کن
      // این برای اطمینان از به‌روز بودن وضعیت است
      // اما فقط اگر Dialog باز نیست
      if (widget.device.ipAddress != null && !widget.isBanned && !_isDialogOpen) {
        _checkStaticStatus();
      }
    }
  }

  /// بارگذاری همه داده‌ها به صورت همزمان و صبر برای تمام شدن
  Future<void> _loadAllData() async {
    if (_isLoadingStatus) return; // جلوگیری از race condition
    _isLoadingStatus = true;

    try {
      // بارگذاری همه داده‌ها به صورت همزمان
      await Future.wait([
        _loadSpeedLimit(),
        _checkStaticStatus(),
      ]);
    } catch (e) {
      print('[STATIC] _loadAllData: خطا در بارگذاری داده‌ها: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingStatus = false;
        });
      }
    }
  }

  // Telegram 功能已禁用，以下函数保留用于将来的平台支持
  // ignore: unused_element
  Future<void> _togglePlatformFilter(String platform, String platformName) async {
    // Telegram 功能已被禁用，只保留 UI
    if (platform == 'telegram') return;
    // 此函数保留用于将来的平台支持
  }

  Future<void> _loadSpeedLimit() async {
    if (widget.device.ipAddress == null) {
      return;
    }
    
    // اگر دستگاه مسدود است، سرعت را لود نکن
    if (widget.isBanned) {
      return;
    }

    try {
      // دریافت لیست Simple Queues
      final service = _serviceManager.service;
      if (service == null || !_serviceManager.isConnected) {
        if (mounted) {
          setState(() {
            _speedLimit = 'N/A';
          });
        }
        return;
      }

      // دریافت لیست queues با timeout
      final queues = await service.getClientSpeed(widget.device.ipAddress!).timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      
      if (mounted) {
        setState(() {
          _speedLimit = queues?['max_limit'] ?? 'N/A';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _speedLimit = 'N/A';
        });
      }
    }
  }

  Future<void> _checkStaticStatus() async {
    // اگر Dialog باز است، بررسی وضعیت را انجام نده
    if (_isDialogOpen) {
      print('[STATIC] _checkStaticStatus: Dialog باز است، بررسی را رد می‌کنم');
      return;
    }

    print('[STATIC] _checkStaticStatus: شروع بررسی وضعیت Static');
    print('[STATIC] IP: ${widget.device.ipAddress}, MAC: ${widget.device.macAddress}, isBanned: ${widget.isBanned}');
    
    if (widget.device.ipAddress == null || widget.isBanned) {
      print('[STATIC] _checkStaticStatus: رد شد - IP یا isBanned null است');
      if (mounted) {
        setState(() {
          _isStatic = null;
          _isLoadingStatic = false;
        });
      }
      return;
    }

    // اگر در حال بارگذاری است، صبر کن
    if (_isLoadingStatic) {
      print('[STATIC] _checkStaticStatus: در حال بارگذاری است، صبر می‌کنم...');
      await Future.delayed(const Duration(milliseconds: 100));
      if (_isLoadingStatic) {
        print('[STATIC] _checkStaticStatus: هنوز در حال بارگذاری است، بازگشت');
        return;
      }
    }

    _isLoadingStatic = true;
    print('[STATIC] _checkStaticStatus: شروع بررسی از Provider');

    try {
      final provider = Provider.of<ClientsProvider>(context, listen: false);
      print('[STATIC] _checkStaticStatus: فراخوانی provider.isDeviceStatic');
      final isStatic = await provider.isDeviceStatic(
        widget.device.ipAddress,
        widget.device.macAddress,
        hostname: widget.device.hostName ?? widget.device.name,
      );
      
      print('[STATIC] _checkStaticStatus: نتیجه بررسی: $isStatic');
      
      if (mounted) {
        setState(() {
          _isStatic = isStatic;
          _isLoadingStatic = false;
        });
        print('[STATIC] _checkStaticStatus: State به‌روزرسانی شد: _isStatic = $isStatic');
      } else {
        print('[STATIC] _checkStaticStatus: Widget mounted نیست، State به‌روزرسانی نشد');
      }
    } catch (e) {
      print('[STATIC] _checkStaticStatus: خطا در بررسی وضعیت Static: $e');
      print('[STATIC] _checkStaticStatus: Stack trace: ${StackTrace.current}');
      if (mounted) {
        setState(() {
          _isStatic = null;
          _isLoadingStatic = false;
        });
      }
    }
  }

  Future<void> _toggleStaticStatus() async {
    print('[STATIC] _toggleStaticStatus: شروع تغییر وضعیت Static');
    print('[STATIC] IP: ${widget.device.ipAddress}, MAC: ${widget.device.macAddress}');
    print('[STATIC] وضعیت فعلی: _isStatic = $_isStatic, _isLoading = $_isLoading');
    
    if (widget.device.ipAddress == null || widget.isBanned || _isLoading) {
      print('[STATIC] _toggleStaticStatus: رد شد - IP: ${widget.device.ipAddress}, isBanned: ${widget.isBanned}, isLoading: $_isLoading');
      return;
    }

    // ذخیره وضعیت فعلی قبل از نمایش Dialog
    final isCurrentlyStatic = _isStatic == true;
    print('[STATIC] _toggleStaticStatus: وضعیت فعلی Static (ذخیره شده): $isCurrentlyStatic');
    
    // تنظیم flag برای جلوگیری از بررسی وضعیت در حین نمایش Dialog
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

    // بستن flag بعد از بسته شدن Dialog
    if (mounted) {
      setState(() {
        _isDialogOpen = false;
      });
    }

    if (confirmed == true) {
      print('[STATIC] _toggleStaticStatus: کاربر تایید کرد، شروع تغییر وضعیت');
      setState(() {
        _isLoading = true;
        _isDialogOpen = true; // جلوگیری از بررسی وضعیت در حین عملیات
      });

      try {
        final provider = Provider.of<ClientsProvider>(context, listen: false);
        print('[STATIC] _toggleStaticStatus: فراخوانی provider.setDeviceStaticStatus');
        print('[STATIC] پارامترها: IP=${widget.device.ipAddress}, MAC=${widget.device.macAddress}, isStatic=${!isCurrentlyStatic}');
        
        final success = await provider.setDeviceStaticStatus(
          widget.device.ipAddress!,
          widget.device.macAddress,
          hostname: widget.device.hostName ?? widget.device.name,
          isStatic: !isCurrentlyStatic,
        );

        print('[STATIC] _toggleStaticStatus: نتیجه تغییر وضعیت: $success');

        if (mounted) {
          if (success) {
            print('[STATIC] _toggleStaticStatus: تغییر وضعیت موفق بود');
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
            // به‌روزرسانی فوری وضعیت بدون بررسی مجدد از سرور
            setState(() {
              _isStatic = !isCurrentlyStatic;
            });
            // بررسی مجدد وضعیت Static بعد از تغییر (با تاخیر)
            print('[STATIC] _toggleStaticStatus: صبر 1000ms و سپس بررسی مجدد وضعیت');
            await Future.delayed(const Duration(milliseconds: 1000));
            // بستن flag قبل از بررسی مجدد
            if (mounted) {
              setState(() {
                _isDialogOpen = false;
              });
            }
            await _checkStaticStatus();
          } else {
            print('[STATIC] _toggleStaticStatus: تغییر وضعیت ناموفق بود');
            print('[STATIC] خطا: ${provider.errorMessage ?? "خطای نامشخص"}');
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
        }
      } catch (e) {
        print('[STATIC] _toggleStaticStatus: خطا در تغییر وضعیت: $e');
        print('[STATIC] Stack trace: ${StackTrace.current}');
        if (mounted) {
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
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isDialogOpen = false; // اطمینان از بسته شدن flag
          });
          print('[STATIC] _toggleStaticStatus: _isLoading = false, _isDialogOpen = false');
        }
      }
    } else {
      print('[STATIC] _toggleStaticStatus: کاربر لغو کرد');
    }
  }

  Future<void> _setSpeedLimit() async {
    if (widget.device.ipAddress == null) return;

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

    if (result != null) {
      setState(() {
        _isLoading = true;
      });

      try {
        // فرمت MikroTik: upload/download
        final speedLimit = '${result['upload']}/${result['download']}';
        final provider = Provider.of<ClientsProvider>(context, listen: false);
        final success = await provider.setClientSpeed(
          widget.device.ipAddress!,
          speedLimit,
        );
        
        if (mounted) {
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
            _loadSpeedLimit();
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
        }
      } catch (e) {
        if (mounted) {
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
    }
  }

  Future<void> _banDevice() async {
    if (widget.device.ipAddress == null) return;

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

    if (confirmed == true) {
      setState(() {
        _isLoading = true;
      });

      try {
        final provider = Provider.of<ClientsProvider>(context, listen: false);
        final success = await provider.banClient(
          widget.device.ipAddress!,
          macAddress: widget.device.macAddress,
          hostname: widget.device.hostName,
          ssid: widget.device.ssid,
        );
        
        if (mounted) {
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
        }
      } catch (e) {
        if (mounted) {
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
    }
  }

  Future<void> _unbanDevice() async {
    if (widget.device.ipAddress == null) return;

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

    if (confirmed == true) {
      setState(() {
        _isLoading = true;
      });

      try {
        final provider = Provider.of<ClientsProvider>(context, listen: false);
        final success = await provider.unbanClient(
          widget.device.ipAddress!,
          macAddress: widget.device.macAddress,
          hostname: widget.device.hostName,
          ssid: widget.device.ssid,
        );
        
        if (mounted) {
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
        }
      } catch (e) {
        if (mounted) {
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

    return Scaffold(
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
                                      'فیلتر Telegram',
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
    );
  }


  List<Widget> _buildPlatformFilterToggles() {
    final platforms = [
      {'key': 'telegram', 'name': 'تلگرام', 'icon': Icons.telegram, 'color': Colors.blue},
    ];

    return platforms.map((platform) {
      final name = platform['name'] as String;
      final icon = platform['icon'] as IconData;
      final color = platform['color'] as Color;
      final isFiltered = false; // Telegram 功能已禁用，状态固定为 false

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.grey.shade300,
            width: 1,
          ),
        ),
        child: ListTile(
          leading: Icon(icon, color: Colors.grey),
          title: Text(
            name,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          trailing: Switch(
            value: isFiltered,
            onChanged: null, // 禁用功能，只保留 UI
            activeColor: color,
          ),
          onTap: null, // 禁用功能，只保留 UI
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

