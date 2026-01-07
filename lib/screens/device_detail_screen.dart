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

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  bool _isLoading = false;
  String? _speedLimit;
  bool? _isStatic;

  static const Color _primaryColor = Color(0xFF428B7C);

  @override
  void initState() {
    super.initState();
    // بارگذاری اطلاعات به صورت غیرهمزمان و بدون blocking کردن UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSpeedLimit();
      _checkStaticStatus();
    });
  }

  Future<void> _checkStaticStatus() async {
    if (widget.device.ipAddress == null || widget.isBanned) {
      return;
    }

    try {
      final isStatic = await _serviceManager.isDeviceStatic(
        widget.device.ipAddress,
        widget.device.macAddress,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      if (mounted) {
        setState(() {
          _isStatic = isStatic;
        });
      }
    } catch (e) {
      // در صورت خطا، وضعیت را null نگه دار (ناشناخته)
      if (mounted) {
        setState(() {
          _isStatic = null;
        });
      }
    }
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

  Future<void> _toggleStaticStatus() async {
    if (widget.device.ipAddress == null) return;

    final isCurrentlyStatic = _isStatic == true;
    final actionText = isCurrentlyStatic ? 'غیر ثابت' : 'ثابت';
    final message = isCurrentlyStatic
        ? 'آیا مطمئن هستید که می‌خواهید دستگاه ${widget.device.ipAddress} را غیر ثابت کنید؟\n\nاین کار باعث می‌شود که:\n• دستگاه از لیست مجاز حذف شود\n• اگر قفل اتصال فعال باشد، دستگاه نمی‌تواند متصل شود\n• دستگاه به عنوان دستگاه جدید شناسایی شود'
        : 'آیا مطمئن هستید که می‌خواهید دستگاه ${widget.device.ipAddress} را ثابت کنید؟\n\nاین کار باعث می‌شود که:\n• دستگاه به لیست مجاز اضافه شود\n• IP دستگاه ثابت بماند\n• اگر قفل اتصال فعال باشد، دستگاه می‌تواند متصل شود';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('تبدیل به $actionText'),
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
            child: Text('تبدیل به $actionText'),
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
        final success = await provider.setDeviceStaticStatus(
          widget.device.ipAddress!,
          widget.device.macAddress,
          hostname: widget.device.hostName,
          isStatic: !isCurrentlyStatic,
        );

        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'دستگاه با موفقیت به $actionText تبدیل شد',
                ),
                backgroundColor: Colors.green,
              ),
            );
            // به‌روزرسانی وضعیت static
            await _checkStaticStatus();
            setState(() {
              _isLoading = false;
            });
            // به‌روزرسانی لیست
            Navigator.pop(context, true);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('خطا: ${provider.errorMessage ?? "خطا در تبدیل دستگاه"}'),
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
                          // نمایش وضعیت static - فقط برای دستگاه‌های ثابت
                          if (_isStatic == true)
                            Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(top: 8),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.green.withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'این دستگاه ثابت است (می‌تواند همیشه متصل شود)',
                                      style: const TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
                        // دکمه تبدیل به static/non-static (فقط برای دستگاه‌های غیرمسدود)
                        if (!widget.isBanned)
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final isWide = constraints.maxWidth > 400;
                              return ElevatedButton.icon(
                                onPressed: _isLoading ? null : _toggleStaticStatus,
                                icon: Icon(
                                  _isStatic == true 
                                      ? Icons.check_circle 
                                      : Icons.radio_button_unchecked,
                                  size: isWide ? 24 : 20,
                                ),
                                label: Text(
                                  _isStatic == true 
                                      ? 'تبدیل به غیر Static' 
                                      : 'تبدیل به Static',
                                  style: TextStyle(
                                    fontSize: isWide ? 18 : 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isStatic == true 
                                      ? Colors.orange 
                                      : _primaryColor,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: Colors.grey.shade300,
                                  padding: EdgeInsets.symmetric(
                                    vertical: isWide ? 16 : 14,
                                    horizontal: isWide ? 24 : 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 2,
                                ),
                              );
                            },
                          ),
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
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
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

