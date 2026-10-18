import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/settings_service.dart';
import '../utils/app_theme.dart';
import '../utils/webview_environment.dart';

/// بعد از بارگذاری، محدودیت viewport (مثل user-scalable=no) را شل می‌کند تا pinch روی اندروید و iOS جواب بدهد.
const String _kUnrestrictViewportForPinchZoom = r'''
(function() {
  try {
    function patch() {
      var nodes = document.querySelectorAll('meta[name="viewport"],meta[name=viewport]');
      var i, el, c;
      for (i = 0; i < nodes.length; i++) {
        el = nodes[i];
        c = el.getAttribute('content') || '';
        c = c.replace(/user-scalable\s*=\s*no/gi, 'user-scalable=yes');
        c = c.replace(/user-scalable\s*=\s*0/gi, 'user-scalable=yes');
        c = c.replace(/maximum-scale\s*=\s*1(?:\.\d+)?/gi, 'maximum-scale=10');
        if (!/user-scalable/i.test(c)) c = (c ? c + ',' : '') + 'user-scalable=yes';
        if (!/minimum-scale/i.test(c)) c += ',minimum-scale=0.25';
        if (!/maximum-scale/i.test(c)) c += ',maximum-scale=10';
        el.setAttribute('content', c);
      }
      if (nodes.length === 0 && document.head) {
        var m = document.createElement('meta');
        m.name = 'viewport';
        m.content = 'width=device-width,initial-scale=1,minimum-scale=0.25,maximum-scale=10,user-scalable=yes';
        document.head.insertBefore(m, document.head.firstChild);
      }
    }
    patch();
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', patch);
    }
  } catch (e) {}
})();
''';

/// صفحه WebView برای سرویس انترنت یا پنل‌های ثابت (مثل اطلاعات وای‌فای)
class InternetServiceScreen extends StatefulWidget {
  const InternetServiceScreen({
    super.key,
    this.fixedUrl,
    this.defaultTitle,
    this.allowUrlChange = true,
  });

  /// در صورت تنظیم، این آدرس به‌جای URL ذخیره‌شده در تنظیمات بارگذاری می‌شود.
  final String? fixedUrl;
  final String? defaultTitle;
  final bool allowUrlChange;

  @override
  State<InternetServiceScreen> createState() => _InternetServiceScreenState();
}

class _InternetServiceScreenState extends State<InternetServiceScreen> {
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

  bool get _preferDesktopExperience =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    try {
      final url = widget.fixedUrl ?? await _settingsService.getServiceUrl();
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

  Future<void> _patchViewportForPinchZoom(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: _kUnrestrictViewportForPinchZoom,
      );
    } catch (e) {
      debugPrint('viewport zoom patch: $e');
    }
  }

  Future<void> _showUrlInputDialog() async {
    if (!widget.allowUrlChange) return;

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primaryColor = AppTheme.primaryFor(theme.brightness);

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Container(
          decoration: BoxDecoration(
            color: primaryColor,
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
          child: AppBar(
            title: Text(
              _pageTitle ?? widget.defaultTitle ?? 'سرویس انترنت',
              overflow: TextOverflow.ellipsis,
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
              if (widget.allowUrlChange)
                IconButton(
                  icon: const Icon(Icons.link),
                  onPressed: _showUrlInputDialog,
                  tooltip: 'تغییر آدرس',
                ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          // WebView
          if (!_showError && _currentUrl != null)
            InAppWebView(
              preventGestureDelay: true,
              webViewEnvironment: windowsWebViewEnvironment,
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  groupName: 'pinch_zoom_viewport',
                  source: _kUnrestrictViewportForPinchZoom,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                ),
              ]),
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
                userAgent: _preferDesktopExperience
                    ? null
                    : 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36',
                // زوم با دو انگشت (pinch) — روی اندروید builtInZoomControls باید true باشد
                supportZoom: true,
                builtInZoomControls: true,
                // دکمه‌های +/- سیستم را نشان نده؛ فقط pinch کافی است
                displayZoomControls: false,
                // iOS: پیش‌فرض کتابخانه min/max=1.0 است و pinch را عملاً غیرفعال می‌کند
                minimumZoomScale: 0.25,
                maximumZoomScale: 5.0,
                // نادیده گرفتن user-scalable=no و محدودیت scale در صفحه
                ignoresViewportScaleLimits: true,
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

                  await _patchViewportForPinchZoom(controller);
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
                if (request.isForMainFrame == false) {
                  return;
                }
                setState(() {
                  _isLoading = false;
                  _showError = true;
                  _errorMessage = 'خطا در بارگذاری صفحه: ${error.description}';
                });
              },
              onReceivedHttpError: (controller, request, response) {
                if (request.isForMainFrame == false) {
                  return;
                }
                final statusCode = response.statusCode;
                if (statusCode != null && statusCode >= 400) {
                  setState(() {
                    _isLoading = false;
                    _showError = true;
                    _errorMessage =
                        'خطای HTTP $statusCode: ${response.reasonPhrase ?? "خطای ناشناخته"}';
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
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                    if (widget.allowUrlChange) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _showUrlInputDialog,
                        icon: const Icon(Icons.link),
                        label: const Text('تغییر آدرس'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryColor,
                          side: BorderSide(color: primaryColor),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            // صفحه بارگذاری اولیه
            const Center(child: CircularProgressIndicator()),

          // نوار پیشرفت بارگذاری
          if (_isLoading && _progress > 0.0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
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
