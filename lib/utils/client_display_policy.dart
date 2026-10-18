import '../models/client_info.dart';
import 'wifi_webview_boards.dart';

/// Rules for which connected clients appear in the list and allow actions.
class ClientDisplayPolicy {
  ClientDisplayPolicy._();

  static bool hasValidIp(String? ip) {
    if (ip == null) {
      return false;
    }
    final trimmed = ip.trim();
    return trimmed.isNotEmpty && trimmed != '0.0.0.0';
  }

  /// Wireless registration with MAC only (typical on LHG/SXT CPE boards).
  static bool isMacOnlyWirelessClient(ClientInfo client) {
    return client.type == 'wireless' && !hasValidIp(client.ipAddress);
  }

  /// Connected list must be DHCP-like entries with a usable IP.
  static bool shouldShowInConnectedList(ClientInfo client) {
    return hasValidIp(client.ipAddress);
  }

  /// Connected tab — devices with a usable IP that are not known to be offline.
  /// `isOnline == null` means not evaluated yet, so it stays visible.
  static bool shouldShowInConnectedListUi(ClientInfo client) {
    if (!shouldShowInConnectedList(client)) {
      return false;
    }
    return client.isOnline != false;
  }

  /// Ban, speed, lease rename, etc. require a target IP.
  static bool shouldAllowDeviceActions(ClientInfo client) {
    return hasValidIp(client.ipAddress);
  }

  /// CPE boards: DHCP only — skip wireless registration enrichment.
  static bool shouldSkipWirelessEnrichment(Map<String, dynamic>? routerInfo) {
    if (routerInfo == null) {
      return true;
    }
    if (routerInfo['wireless-features-enabled'] == false) {
      return true;
    }
    return isWifiWebViewBoard(routerInfo);
  }
}
