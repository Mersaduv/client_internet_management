import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Shared WebView2 environment for Windows (writable user-data folder).
WebViewEnvironment? windowsWebViewEnvironment;

/// Creates a WebView2 environment under LocalAppData so installs in
/// Program Files do not get a blank WebView (cache next to the .exe fails).
Future<void> ensureWindowsWebViewEnvironment() async {
  if (kIsWeb || !Platform.isWindows || windowsWebViewEnvironment != null) {
    return;
  }

  try {
    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    if (availableVersion == null) {
      debugPrint('[WEBVIEW2] runtime not found');
      return;
    }

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      debugPrint('[WEBVIEW2] LOCALAPPDATA missing');
      return;
    }

    final userDataFolder = '$localAppData\\Ariyabod\\WebView2';
    await Directory(userDataFolder).create(recursive: true);

    windowsWebViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: userDataFolder),
    );
    debugPrint('[WEBVIEW2] userDataFolder=$userDataFolder');
  } catch (e) {
    debugPrint('[WEBVIEW2] environment init failed: $e');
  }
}
