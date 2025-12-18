import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/settings_service.dart';

/// صفحه سرویس انترنت با WebView کامل
class InternetServiceScreen extends StatefulWidget {
  const InternetServiceScreen({super.key});

  @override
  State<InternetServiceScreen> createState() => _InternetServiceScreenState();
}

class _InternetServiceScreenState extends State<InternetServiceScreen> {
  static const Color _primaryColor = Color(0xFF428B7C);
  
  InAppWebViewController? _webViewController;
  final SettingsService _settingsService = SettingsService();
  
  bool _isLoading = true;
  double _progress = 0.0;
  String? _currentUrl;
  String? _pageTitle;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _errorMessage;
  bool _showError = false;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    try {
      final url = await _settingsService.getServiceUrl();
      if (mounted) {
        setState(() {
          _currentUrl = url;
          _errorMessage = null;
          _showError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'خطا در بارگذاری URL: $e';
          _showError = true;
        });
      }
    }
  }

  Future<void> _reload() async {
    if (_webViewController != null) {
      await _webViewController!.reload();
    } else {
      await _loadUrl();
    }
  }

  Future<void> _goBack() async {
    if (_webViewController != null && _canGoBack) {
      try {
        await _webViewController!.goBack();
      } catch (e) {
        debugPrint('Error in goBack: $e');
      }
    }
  }

  Future<void> _goForward() async {
    if (_webViewController != null && _canGoForward) {
      try {
        await _webViewController!.goForward();
      } catch (e) {
        debugPrint('Error in goForward: $e');
      }
    }
  }

  Future<void> _showUrlInputDialog() async {
    final urlController = TextEditingController(text: _currentUrl);
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ورود آدرس سایت'),
        content: TextField(
          controller: urlController,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'https://example.com',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          textDirection: TextDirection.ltr,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('لغو'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, urlController.text),
            child: const Text('بارگذاری'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      String url = result.trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }
      
      // ذخیره URL در تنظیمات
      await _settingsService.setServiceUrl(url);
      
      if (_webViewController != null) {
        await _webViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(url)),
        );
      } else {
        setState(() {
          _currentUrl = url;
          _errorMessage = null;
          _showError = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _pageTitle ?? 'سرویس انترنت',
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // دکمه بازگشت
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _canGoBack ? _goBack : null,
            tooltip: 'بازگشت',
          ),
          // دکمه جلو
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: _canGoForward ? _goForward : null,
            tooltip: 'جلو',
          ),
          // دکمه رفرش
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
            tooltip: 'بارگذاری مجدد',
          ),
          // دکمه تنظیمات URL
          IconButton(
            icon: const Icon(Icons.link),
            onPressed: _showUrlInputDialog,
            tooltip: 'تغییر آدرس',
          ),
        ],
      ),
      body: Stack(
        children: [
          // WebView
          if (!_showError && _currentUrl != null)
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_currentUrl!)),
              initialSettings: InAppWebViewSettings(
                // فعال‌سازی JavaScript
                javaScriptEnabled: true,
                // فعال‌سازی DOM Storage
                domStorageEnabled: true,
                // فعال‌سازی Database
                databaseEnabled: true,
                // فعال‌سازی Local Storage
                javaScriptCanOpenWindowsAutomatically: true,
                // پشتیبانی از تمام ویژگی‌های وب
                useHybridComposition: true,
                // پشتیبانی از فایل‌ها
                useShouldOverrideUrlLoading: true,
                // پشتیبانی از Media Playback
                mediaPlaybackRequiresUserGesture: false,
                // پشتیبانی از Geolocation
                allowsInlineMediaPlayback: true,
                // پشتیبانی از File Access
                allowsBackForwardNavigationGestures: true,
                // تنظیمات User Agent
                userAgent: 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36',
                // پشتیبانی از فرم‌ها
                supportZoom: true,
                builtInZoomControls: false,
                displayZoomControls: false,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
              },
              onLoadStart: (controller, url) {
                setState(() {
                  _isLoading = true;
                  _progress = 0.0;
                  _showError = false;
                  _errorMessage = null;
                });
              },
              onLoadStop: (controller, url) async {
                setState(() {
                  _isLoading = false;
                  _currentUrl = url.toString();
                });
                
                try {
                  // دریافت عنوان صفحه
                  final title = await controller.getTitle();
                  if (title != null && mounted) {
                    setState(() {
                      _pageTitle = title;
                    });
                  }
                  
                  // بررسی قابلیت‌های ناوبری (با try-catch برای جلوگیری از خطا)
                  try {
                    final canGoBack = await controller.canGoBack();
                    final canGoForward = await controller.canGoForward();
                    if (mounted) {
                      setState(() {
                        _canGoBack = canGoBack;
                        _canGoForward = canGoForward;
                      });
                    }
                  } catch (e) {
                    // در صورت خطا، مقادیر پیش‌فرض را تنظیم کن
                    if (mounted) {
                      setState(() {
                        _canGoBack = false;
                        _canGoForward = false;
                      });
                    }
                  }
                } catch (e) {
                  // خطا در دریافت اطلاعات صفحه - نادیده بگیر
                  debugPrint('Error in onLoadStop: $e');
                }
              },
              onProgressChanged: (controller, progress) {
                setState(() {
                  _progress = progress / 100;
                });
              },
              onReceivedError: (controller, request, error) {
                setState(() {
                  _isLoading = false;
                  _showError = true;
                  _errorMessage = 'خطا در بارگذاری صفحه: ${error.description}';
                });
              },
              onReceivedHttpError: (controller, request, response) {
                final statusCode = response.statusCode;
                if (statusCode != null && statusCode >= 400) {
                  setState(() {
                    _isLoading = false;
                    _showError = true;
                    _errorMessage = 'خطای HTTP $statusCode: ${response.reasonPhrase ?? "خطای ناشناخته"}';
                  });
                }
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                // اجازه بارگذاری تمام URL ها
                return NavigationActionPolicy.ALLOW;
              },
            )
          else if (_showError)
            // صفحه خطا
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.red.shade300,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'خطا در بارگذاری',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _errorMessage ?? 'خطای ناشناخته',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('تلاش مجدد'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _showUrlInputDialog,
                      icon: const Icon(Icons.link),
                      label: const Text('تغییر آدرس'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _primaryColor,
                        side: BorderSide(color: _primaryColor),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            // صفحه بارگذاری اولیه
            const Center(
              child: CircularProgressIndicator(),
            ),
          
          // نوار پیشرفت بارگذاری
          if (_isLoading && _progress > 0.0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(_primaryColor),
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _webViewController?.dispose();
    super.dispose();
  }
}
