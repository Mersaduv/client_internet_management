import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../models/client_info.dart';
import '../models/client_traffic_rate.dart';
import '../services/client_traffic_store.dart';
import '../services/mikrotik_service_manager.dart';
import '../services/mikrotik_timeouts.dart';
import '../services/network_info_service.dart';
import '../services/traffic_stream_coordinator.dart';
import '../utils/client_display_name.dart';
import '../utils/client_display_policy.dart';
import '../utils/current_device_policy.dart';
import '../utils/device_list_pagination.dart';
import '../utils/routeros_duration_parser.dart';

enum LoadingPhase { idle, counts, phase1, phase2, phase3, complete }

/// Provider برای مدیریت state کلاینت‌ها به صورت real-time
class ClientsProvider extends ChangeNotifier {
  final MikroTikServiceManager _serviceManager = MikroTikServiceManager();
  static const Duration _fastCountTimeout = Duration(seconds: 8);
  static const Duration _autoStaticTimeout = Duration(seconds: 10);
  static const Duration _bannedClientsTimeout = Duration(seconds: 10);
  static const Duration _phase2StepTimeout = Duration(seconds: 18);
  static const Duration _phase3Timeout = MikrotikTimeouts.phaseTalk;
  static const Duration _phase1Timeout = MikrotikTimeouts.phase1;
  static const Duration _onlineRefreshTimeout = MikrotikTimeouts.onlineRefresh;
  static const Duration _unbanTimeout = Duration(seconds: 45);
  static const Duration _lockStatusCacheTtl = Duration(seconds: 30);
  static const String _banMarker = '[Ariyabod BAN]';
  static const int offlineThresholdSeconds = 300;
  static const Duration statusRefreshInterval =
      MikrotikTimeouts.statusRefreshInterval;
  static const Duration trafficPollInterval =
      MikrotikTimeouts.trafficPollInterval;

  // State variables
  bool _isLoading = false;
  bool _isDataComplete = false;
  bool _phase1Complete = false;
  bool _phase2Complete = false;
  bool _phase3Complete = false;
  LoadingPhase _currentPhase = LoadingPhase.idle;
  bool _bannedListLoaded = false;
  bool _isBannedListLoading = false;
  bool _isBannedEnriching = false;
  DateTime? _bannedListLoadingStartedAt;
  DateTime? _lockStatusCachedAt;
  List<ClientInfo> _clients = [];
  List<Map<String, dynamic>> _bannedClients = [];
  String? _errorMessage;
  String? _deviceIp;
  String? _deviceMac;
  bool _isRefreshing = false;
  Map<String, dynamic>? _routerInfo;
  bool _isNewConnectionsLocked = false;
  bool _isLockUpdating = false;
  bool _isEnsuringCurrentDeviceStatic = false;
  String? _lastAutoStaticIp;
  final Set<String> _approvalActionsInProgress = <String>{};
  Future<void>? _activeRefreshFuture;
  Timer? _onlineStatusTimer;
  TrafficStreamCoordinator? _trafficStreamCoordinator;
  bool _trafficPollInProgress = false;
  final ClientTrafficStore _trafficStore = ClientTrafficStore();
  bool _suppressNotifications = false;
  int _pendingNotifications = 0;
  bool _apiOperationInProgress = false;
  String? _activeOperationDeviceMac;

  // Fast tab counts + paginated connected list window
  int? _connectedCountHint;
  int? _bannedCountHint;
  List<ClientInfo> _displayClientsCache = [];
  int _visibleClientLimit = 0;
  bool _isLoadingMoreConnected = false;
  int _visibleBannedLimit = 0;
  bool _isLoadingMoreBanned = false;
  final Set<int> _trafficVisibleListIndices = {};
  final Set<String> _trafficActivePollIps = {};
  Timer? _trafficViewportSyncTimer;
  Timer? _trafficPlaceholderTimer;
  Timer? _trafficDisplayTimer;
  final Set<String> _pinnedTrafficIps = {};

  static const Duration _trafficViewportSyncDelay = Duration(milliseconds: 200);
  static const int _trafficViewportIndexPad = 2;

  // Getters
  bool get isLoading => _isLoading;
  bool get isDataComplete => _isDataComplete;
  bool get phase1Complete => _phase1Complete;
  bool get phase2Complete => _phase2Complete;
  bool get phase3Complete => _phase3Complete;
  LoadingPhase get currentPhase => _currentPhase;
  bool get trafficPollReady => _trafficStore.pollReady;
  bool get trafficUiEnabled => _phase1Complete;

  bool trafficMeasuredForIp(String? ip) => _trafficStore.isMeasured(ip);
  bool trafficAwaitingTimedOut(String? ip) =>
      _trafficStore.awaitingFirstSampleTimedOut(ip);
  bool get bannedListLoaded => _bannedListLoaded;
  bool get isBannedListLoading => _isBannedListLoading;
  bool get showBannedLoadingSkeleton {
    if (_bannedClients.isNotEmpty) {
      return false;
    }
    if ((_bannedCountHint ?? 0) > 0 && !_bannedListLoaded) {
      return true;
    }
    if (!_isBannedListLoading || _bannedListLoaded) {
      return false;
    }
    final startedAt = _bannedListLoadingStartedAt;
    if (startedAt == null) {
      return true;
    }
    return DateTime.now().difference(startedAt) < const Duration(seconds: 8);
  }

  List<ClientInfo> get clients => _clients;

  int get connectedTabCount =>
      _connectedCountHint ?? _displayClientsCache.length;
  int get bannedTabCount => _bannedCountHint ?? _bannedClients.length;
  int get totalConnectedCount => _displayClientsCache.length;
  bool get hasMoreConnectedToShow =>
      _visibleClientLimit < _displayClientsCache.length;
  bool get isLoadingMoreConnected => _isLoadingMoreConnected;
  bool get hasMoreBannedToShow => _visibleBannedLimit < _bannedClients.length;
  bool get isLoadingMoreBanned => _isLoadingMoreBanned;

  /// Whether [ip] is actively polled (scroll viewport or detail pin).
  bool isTrafficPollTarget(String? ip) {
    final normalized = ip?.trim();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    if (_pinnedTrafficIps.contains(normalized)) {
      return true;
    }
    return _trafficTrackingContext().ips.contains(normalized);
  }

  bool isTrafficPinnedIp(String? ip) {
    final normalized = ip?.trim();
    return normalized != null && _pinnedTrafficIps.contains(normalized);
  }

  /// Detail screen — always include this IP in the live traffic poll set.
  void pinTrafficMonitoring(String? ip) {
    final normalized = ip?.trim();
    if (normalized == null || normalized.isEmpty || normalized == '0.0.0.0') {
      return;
    }
    if (_pinnedTrafficIps.add(normalized)) {
      _trafficActivePollIps.add(normalized);
      _trafficStore.onViewportChanged(Set<String>.from(_trafficActivePollIps));
      _configureTrafficStream();
      _scheduleTrafficPollForNewClients();
      _trafficStreamCoordinator?.wake();
      _armTrafficPlaceholderWatch();
      notifyListeners();
    }
  }

  void unpinTrafficMonitoring(String? ip) {
    final normalized = ip?.trim();
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    if (_pinnedTrafficIps.remove(normalized)) {
      _scheduleTrafficViewportSync();
    }
  }

  /// Per-row visibility from [TrafficListItemVisibility] — starts/stops poll IPs.
  void reportTrafficListItemVisibility(int index, bool visible) {
    if (index < 0) {
      return;
    }

    final changed = visible
        ? _trafficVisibleListIndices.add(index)
        : _trafficVisibleListIndices.remove(index);
    if (changed) {
      _scheduleTrafficViewportSync();
    }
  }

  void _scheduleTrafficViewportSync() {
    _trafficViewportSyncTimer?.cancel();
    _trafficViewportSyncTimer = Timer(_trafficViewportSyncDelay, () {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _syncTrafficViewportFromVisibleRows();
      });
    });
  }

  void _cancelTrafficViewportSyncTimer() {
    _trafficViewportSyncTimer?.cancel();
    _trafficViewportSyncTimer = null;
    _trafficPlaceholderTimer?.cancel();
    _trafficPlaceholderTimer = null;
  }

  void _armTrafficPlaceholderWatch() {
    _trafficPlaceholderTimer?.cancel();
    if (!_trafficStore.hasUnmeasuredActiveIps) {
      _trafficPlaceholderTimer = null;
      return;
    }
    _trafficPlaceholderTimer = Timer(_trafficStore.placeholderTimeout, () {
      _trafficPlaceholderTimer = null;
      if (_trafficStore.hasUnmeasuredActiveIps) {
        notifyListeners();
      }
    });
  }

  /// Called from [TrafficListScrollScope] after the list scrolls.
  void notifyTrafficListScrolled() {
    _scheduleTrafficViewportSync();
  }

  /// Rebuilds the active poll IP set from rows intersecting the scroll viewport.
  void _syncTrafficViewportFromVisibleRows() {
    final displayed = clientsForDisplay;
    _trafficVisibleListIndices.removeWhere(
      (index) => index >= displayed.length,
    );

    final nextIps = <String>{..._pinnedTrafficIps};

    if (displayed.isNotEmpty) {
      for (final index in _trafficVisibleListIndices) {
        if (index < 0 || index >= displayed.length) {
          continue;
        }
        final start = index - _trafficViewportIndexPad;
        final end = index + _trafficViewportIndexPad;
        for (var i = start; i <= end; i++) {
          if (i < 0 || i >= displayed.length) {
            continue;
          }
          final client = displayed[i];
          if (!ClientDisplayPolicy.shouldShowInConnectedList(client)) {
            continue;
          }
          final ip = client.ipAddress?.trim();
          if (ip != null && ip.isNotEmpty && ip != '0.0.0.0') {
            nextIps.add(ip);
          }
        }
      }
    }

    if (setEquals(nextIps, _trafficActivePollIps)) {
      return;
    }

    _trafficActivePollIps
      ..clear()
      ..addAll(nextIps);
    _trafficStore.onViewportChanged(Set<String>.from(_trafficActivePollIps));
    _configureTrafficStream();
    _scheduleTrafficPollForNewClients();
    _trafficStreamCoordinator?.wake();
    _armTrafficPlaceholderWatch();
    if (_trafficActivePollIps.isNotEmpty &&
        _trafficStreamCoordinator?.isRunning != true) {
      _startTrafficStream();
    }
    notifyListeners();
  }

  /// Legacy scroll hook — triggers visibility resync after programmatic scroll.
  void updateTrafficViewportFromScroll({
    required double scrollOffset,
    required double viewportHeight,
  }) {
    _scheduleTrafficViewportSync();
  }

  void _seedInitialTrafficViewport() {
    _scheduleTrafficViewportSync();
  }

  /// ListView row built — grow window; viewport comes from scroll offset.
  void noteListItemVisible(int index) {
    if (index < 0) {
      return;
    }
    ensureConnectedVisibleThrough(index);
  }

  /// Grow the rendered list window so [index] is included.
  void ensureConnectedVisibleThrough(int index) {
    if (index < 0 || _displayClientsCache.isEmpty) {
      return;
    }

    final needed = DeviceListPagination.clampLimit(
      index + 1 + DeviceListPagination.prefetchThreshold,
      _displayClientsCache.length,
    );
    if (needed <= _visibleClientLimit) {
      return;
    }

    _visibleClientLimit = needed;
    _isLoadingMoreConnected = false;
    _scheduleTrafficPollForNewClients();
    notifyListeners();
  }

  /// Devices currently rendered in the connected tab (windowed).
  List<ClientInfo> get clientsForDisplay {
    if (_displayClientsCache.isEmpty) {
      return _clients
          .where(ClientDisplayPolicy.shouldShowInConnectedListUi)
          .toList();
    }
    final limit = DeviceListPagination.clampLimit(
      _visibleClientLimit,
      _displayClientsCache.length,
    );
    return _displayClientsCache.sublist(0, limit);
  }

  /// Banned tab window — full list loads lazily; UI shows a slice.
  List<Map<String, dynamic>> get bannedClientsForDisplay {
    if (_bannedClients.isEmpty) {
      return const [];
    }
    final limit = DeviceListPagination.clampLimit(
      _visibleBannedLimit,
      _bannedClients.length,
    );
    return _bannedClients.sublist(0, limit);
  }

  List<Map<String, dynamic>> get bannedClients => _bannedClients;
  String? get errorMessage => _errorMessage;
  String? get deviceIp => _deviceIp;
  String? get deviceMac => _deviceMac;

  bool isCurrentDevice(ClientInfo client) {
    return CurrentDevicePolicy.isCurrentDevice(
      client: client,
      deviceIp: _deviceIp,
      deviceMac: _deviceMac,
      clients: _clients,
    );
  }

  void _applyResolvedDeviceIdentity(String? ip, {List<ClientInfo>? clients}) {
    final resolved = CurrentDevicePolicy.pickBestDeviceIp(
      localIp: ip ?? _deviceIp,
      routerReportedIp: ip,
      clients: clients ?? _clients,
      routerHost: _serviceManager.currentConnection?.host,
    );
    if (resolved == null || resolved.isEmpty) {
      return;
    }

    final changed = resolved != _deviceIp;
    _deviceIp = resolved;
    final mac = CurrentDevicePolicy.macForDeviceIp(
      clients ?? _clients,
      resolved,
    );
    if (mac != null) {
      _deviceMac = mac;
    }
    if (changed) {
      _sortClientsForDisplay();
    }
  }

  Future<void> _resolveDeviceIdentityEarly() async {
    try {
      final localIp = await NetworkInfoService().getDeviceIPv4Address();
      if (localIp != null && localIp.isNotEmpty) {
        _applyResolvedDeviceIdentity(localIp);
        notifyListeners();
      }
    } catch (_) {
      // Keep going; phase 3 will retry.
    }
  }

  bool get isRefreshing => _isRefreshing;
  bool get isConnected => _serviceManager.isConnected;
  Map<String, dynamic>? get routerInfo => _routerInfo;

  bool get isNewConnectionsLocked => _isNewConnectionsLocked;
  bool get isLockUpdating => _isLockUpdating;
  String? get activeOperationDeviceMac => _activeOperationDeviceMac;

  @override
  void notifyListeners() {
    if (_suppressNotifications) {
      _pendingNotifications++;
      return;
    }
    super.notifyListeners();
  }

  void notifyListenersImmediate() => super.notifyListeners();

  Future<T> _withBatchedNotifications<T>(Future<T> Function() action) async {
    _suppressNotifications = true;
    _pendingNotifications = 0;
    try {
      return await action();
    } finally {
      _suppressNotifications = false;
      if (_pendingNotifications > 0) {
        _pendingNotifications = 0;
        super.notifyListeners();
      }
    }
  }

  Future<T> _runUserApiOperation<T>(Future<T> Function() action) async {
    _apiOperationInProgress = true;
    _trafficStreamCoordinator?.stop();
    try {
      await _serviceManager.disconnectTrafficMonitor();
      await _serviceManager.ensureSessionHealthy();
      return await _withBatchedNotifications(action);
    } finally {
      _apiOperationInProgress = false;
      _resumeTrafficAfterUserOp();
    }
  }

  void _resumeTrafficAfterUserOp() {
    if (!_phase1Complete || _clients.isEmpty || !_serviceManager.isConnected) {
      return;
    }
    if (_trafficStreamCoordinator?.isRunning == true) {
      _scheduleTrafficPollForNewClients();
      return;
    }
    _startTrafficStream();
  }

  String? _operationKeyForClient({String? macAddress, String? ipAddress}) {
    final mac = macAddress?.trim().toUpperCase();
    if (mac != null && mac.isNotEmpty) {
      return mac;
    }
    final ip = ipAddress?.trim();
    if (ip != null && ip.isNotEmpty) {
      return ip;
    }
    return null;
  }

  bool _isOperationTarget(ClientInfo client, String? operationKey) {
    if (operationKey == null) {
      return false;
    }
    final mac = client.macAddress?.trim().toUpperCase();
    if (mac != null && mac.isNotEmpty && mac == operationKey) {
      return true;
    }
    return client.ipAddress?.trim() == operationKey;
  }

  bool isDeviceUnderOperation(ClientInfo client) {
    return _isOperationTarget(client, _activeOperationDeviceMac);
  }

  bool _isCurrentDeviceTarget(String ipAddress, {String? macAddress}) {
    return CurrentDevicePolicy.isCurrentTarget(
      ipAddress: ipAddress,
      macAddress: macAddress,
      deviceIp: _deviceIp,
      deviceMac: _deviceMac,
      clients: _clients,
    );
  }

  int? _lastIpOctet(String? ipAddress) {
    if (ipAddress == null || ipAddress.isEmpty) {
      return null;
    }
    final parts = ipAddress.trim().split('.');
    if (parts.length != 4) {
      return null;
    }
    return int.tryParse(parts.last);
  }

  int? _ipToSortableInt(String? ipAddress) {
    if (ipAddress == null || ipAddress.isEmpty) {
      return null;
    }
    final parts = ipAddress.trim().split('.');
    if (parts.length != 4) {
      return null;
    }

    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((part) => part == null)) {
      return null;
    }

    return (numbers[0]! << 24) |
        (numbers[1]! << 16) |
        (numbers[2]! << 8) |
        numbers[3]!;
  }

  int _compareClientsByIpOrder(ClientInfo a, ClientInfo b) {
    final aLastOctet = _lastIpOctet(a.ipAddress);
    final bLastOctet = _lastIpOctet(b.ipAddress);

    if (aLastOctet != null && bLastOctet != null) {
      final byLastOctet = aLastOctet.compareTo(bLastOctet);
      if (byLastOctet != 0) {
        return byLastOctet;
      }
    } else if (aLastOctet != null) {
      return -1;
    } else if (bLastOctet != null) {
      return 1;
    }

    final aFullIp = _ipToSortableInt(a.ipAddress);
    final bFullIp = _ipToSortableInt(b.ipAddress);
    if (aFullIp != null && bFullIp != null) {
      final byFullIp = aFullIp.compareTo(bFullIp);
      if (byFullIp != 0) {
        return byFullIp;
      }
    } else if (aFullIp != null) {
      return -1;
    } else if (bFullIp != null) {
      return 1;
    }

    final aName = (a.hostName ?? a.name ?? a.user ?? '').toLowerCase();
    final bName = (b.hostName ?? b.name ?? b.user ?? '').toLowerCase();
    return aName.compareTo(bName);
  }

  bool _isStaticClient(ClientInfo client) {
    if (client.isStaticLease == true) {
      return true;
    }
    final dynamicValue = client.rawData['dynamic']?.toString().toLowerCase();
    return dynamicValue == 'false' || dynamicValue == 'no';
  }

  int _compareClientsForDisplay(ClientInfo a, ClientInfo b) {
    if (_deviceIp != null && _deviceIp!.isNotEmpty) {
      final aIsCurrent = isCurrentDevice(a);
      final bIsCurrent = isCurrentDevice(b);
      if (aIsCurrent && !bIsCurrent) {
        return -1;
      }
      if (!aIsCurrent && bIsCurrent) {
        return 1;
      }
    }

    final aIsStatic = _isStaticClient(a);
    final bIsStatic = _isStaticClient(b);
    if (aIsStatic != bIsStatic) {
      return aIsStatic ? -1 : 1;
    }

    return _compareClientsByIpOrder(a, b);
  }

  void _sortClientsForDisplay() {
    _clients.sort(_compareClientsForDisplay);
    _rebuildDisplayCache();
  }

  void _rebuildDisplayCache() {
    _displayClientsCache = _clients
        .where(ClientDisplayPolicy.shouldShowInConnectedListUi)
        .toList();
    _connectedCountHint = _displayClientsCache.length;
    if (_visibleClientLimit > _displayClientsCache.length) {
      _visibleClientLimit = _displayClientsCache.length;
    }
    if (_displayClientsCache.isNotEmpty && _visibleClientLimit == 0) {
      _visibleClientLimit = DeviceListPagination.initialPageSize.clamp(
        1,
        _displayClientsCache.length,
      );
    }
  }

  void _resetConnectedWindow() {
    _displayClientsCache = [];
    _visibleClientLimit = 0;
    _isLoadingMoreConnected = false;
    _cancelTrafficViewportSyncTimer();
    _trafficVisibleListIndices.clear();
    _trafficActivePollIps.clear();
    _pinnedTrafficIps.clear();
  }

  void _resetBannedWindow() {
    _visibleBannedLimit = 0;
    _isLoadingMoreBanned = false;
  }

  void _ensureBannedWindowInitialized() {
    if (_bannedClients.isEmpty) {
      _visibleBannedLimit = 0;
      return;
    }
    if (_visibleBannedLimit == 0) {
      _visibleBannedLimit = DeviceListPagination.initialPageSize.clamp(
        1,
        _bannedClients.length,
      );
    }
  }

  /// Fetch banned count + list immediately from one lightweight raw query.
  Future<void> prefetchTabCounts() async {
    if (!_serviceManager.isConnected) {
      return;
    }
    try {
      final bannedList = await _serviceManager.getBannedClientsFast().timeout(
        _fastCountTimeout,
        onTimeout: () => _bannedClients,
      );
      _applyBannedList(bannedList, markLoaded: true);
      notifyListeners();
      unawaited(_enrichBannedClients());
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] fast banned list failed: $e');
    }
  }

  void _applyBannedList(
    List<Map<String, dynamic>> bannedList, {
    required bool markLoaded,
  }) {
    _bannedClients = bannedList;
    _bannedCountHint = bannedList.length;
    if (markLoaded) {
      _bannedListLoaded = true;
    }
    _ensureBannedWindowInitialized();
  }

  void _resetPaginationLoadingState() {
    _isLoadingMoreConnected = false;
    _isLoadingMoreBanned = false;
  }

  void maybePrefetchConnectedAtIndex(int index) {
    if (!hasMoreConnectedToShow || _isLoadingMoreConnected) {
      return;
    }
    final visible = clientsForDisplay.length;
    if (index < visible - DeviceListPagination.prefetchThreshold) {
      return;
    }
    loadMoreConnectedDevices();
  }

  void loadMoreConnectedDevices() {
    if (!hasMoreConnectedToShow) {
      _isLoadingMoreConnected = false;
      return;
    }

    _visibleClientLimit = DeviceListPagination.clampLimit(
      _visibleClientLimit + DeviceListPagination.pageSize,
      _displayClientsCache.length,
    );
    _isLoadingMoreConnected = false;
    _scheduleTrafficPollForNewClients();
    notifyListeners();
  }

  void maybePrefetchBannedAtIndex(int index) {
    if (!hasMoreBannedToShow || _isLoadingMoreBanned) {
      return;
    }
    final visible = bannedClientsForDisplay.length;
    if (index < visible - DeviceListPagination.prefetchThreshold) {
      return;
    }
    loadMoreBannedDevices();
  }

  void loadMoreBannedDevices() {
    if (!hasMoreBannedToShow) {
      _isLoadingMoreBanned = false;
      return;
    }

    _visibleBannedLimit = DeviceListPagination.clampLimit(
      _visibleBannedLimit + DeviceListPagination.pageSize,
      _bannedClients.length,
    );
    _isLoadingMoreBanned = false;
    notifyListeners();
  }

  List<ClientInfo> get _trafficTrackedClients {
    final displayed = clientsForDisplay;
    if (_trafficActivePollIps.isEmpty && _pinnedTrafficIps.isEmpty) {
      return const [];
    }

    if (displayed.isEmpty) {
      return _resolvePinnedClients(const []);
    }

    final clients = <ClientInfo>[];
    for (final client in displayed) {
      if (!ClientDisplayPolicy.shouldShowInConnectedList(client)) {
        continue;
      }
      final ip = client.ipAddress?.trim();
      if (ip != null && _trafficActivePollIps.contains(ip)) {
        clients.add(client);
      }
    }

    return _resolvePinnedClients(clients);
  }

  List<ClientInfo> _resolvePinnedClients(List<ClientInfo> base) {
    if (_pinnedTrafficIps.isEmpty) {
      return base;
    }

    final merged = List<ClientInfo>.from(base);
    final presentIps = merged
        .map((c) => c.ipAddress?.trim())
        .whereType<String>()
        .toSet();

    for (final ip in _pinnedTrafficIps) {
      if (presentIps.contains(ip)) {
        continue;
      }
      for (final client in _clients) {
        if (client.ipAddress?.trim() == ip) {
          merged.add(client);
          presentIps.add(ip);
          break;
        }
      }
    }
    return merged;
  }

  bool _isBannedComment(String? comment) {
    final value = comment ?? '';
    return value.contains(_banMarker) ||
        value.contains('Banned via Flutter App') ||
        value.startsWith('Auto-banned:') ||
        value.startsWith('Banned:');
  }

  bool _isClientBanned(ClientInfo client) {
    if (client.rawData['is_banned'] == true) {
      return true;
    }
    final blockAccess = client.rawData['block-access']
        ?.toString()
        .toLowerCase();
    return blockAccess == 'yes' || blockAccess == 'true';
  }

  ({Set<String> ips, Set<String> macs}) _bannedTargetSets() {
    final ips = <String>{};
    final macs = <String>{};
    for (final banned in _bannedClients) {
      final ip = banned['address']?.toString().trim();
      final mac = banned['mac_address']?.toString().toUpperCase();
      if (ip != null && ip.isNotEmpty) {
        ips.add(ip);
      }
      if (mac != null && mac.isNotEmpty) {
        macs.add(mac);
      }
    }
    return (ips: ips, macs: macs);
  }

  bool _isTargetInBannedLists({String? ip, String? mac}) {
    final targets = _bannedTargetSets();
    final normalizedMac = mac?.toUpperCase();
    final normalizedIp = ip?.trim();
    if (normalizedIp != null &&
        normalizedIp.isNotEmpty &&
        targets.ips.contains(normalizedIp)) {
      return true;
    }
    return normalizedMac != null &&
        normalizedMac.isNotEmpty &&
        targets.macs.contains(normalizedMac);
  }

  void _filterBannedFromConnectedList() {
    final targets = _bannedTargetSets();
    _clients = _clients.where((client) {
      if (_isClientBanned(client)) {
        return false;
      }
      final mac = client.macAddress?.toUpperCase();
      final ip = client.ipAddress;
      if (mac != null && targets.macs.contains(mac)) {
        return false;
      }
      if (ip != null && targets.ips.contains(ip)) {
        return false;
      }
      return true;
    }).toList();
    _clients = _clients
        .where(ClientDisplayPolicy.shouldShowInConnectedList)
        .toList();
    _rebuildDisplayCache();
  }

  /// هم‌تراز کردن شمارش تب‌های متصل/مسدود پس از ban یا unban (بدون refresh کامل).
  void reconcileHomeListsAfterBanOrUnban() {
    _filterBannedFromConnectedList();
    _sortClientsForDisplay();
    notifyListeners();
  }

  String? _displayNameFromLease(Map<String, String> lease) {
    return ClientDisplayName.displayNameFromLease(lease);
  }

  String? _neighborIdentityForMac(
    String mac,
    List<Map<String, String>> neighbors,
  ) {
    final normalizedMac = mac.toUpperCase();
    for (final neighbor in neighbors) {
      final neighborMac = neighbor['mac-address']?.trim().toUpperCase();
      if (neighborMac != normalizedMac) {
        continue;
      }
      final identity = neighbor['identity']?.trim();
      if (identity != null && identity.isNotEmpty) {
        return identity;
      }
    }
    return null;
  }

  void _applyNeighborIdentities(List<Map<String, String>> neighbors) {
    if (neighbors.isEmpty) {
      return;
    }

    var changed = false;
    for (var i = 0; i < _clients.length; i++) {
      final client = _clients[i];
      final currentName = ClientDisplayName.resolveHostName(client);
      if (currentName != null && currentName.isNotEmpty) {
        continue;
      }

      final mac = client.macAddress?.trim().toUpperCase();
      if (mac == null || mac.isEmpty) {
        continue;
      }

      final identity = _neighborIdentityForMac(mac, neighbors);
      if (identity == null) {
        continue;
      }

      final rawData = Map<String, dynamic>.from(client.rawData)
        ..['identity'] = identity;
      _clients[i] = client.copyWith(hostName: identity, rawData: rawData);
      changed = true;
    }

    if (changed) {
      _sortClientsForDisplay();
      notifyListeners();
    }
  }

  ClientInfo _clientFromDhcpLease(Map<String, String> lease) {
    final dynamicValue = lease['dynamic']?.toLowerCase();
    final isStatic = dynamicValue == 'false' || dynamicValue == 'no';
    final comment = lease['comment'];
    final isBanned =
        _isBannedComment(comment) ||
        lease['block-access']?.toLowerCase() == 'yes';

    final rawData = Map<String, dynamic>.from(lease)..['is_banned'] = isBanned;

    return ClientInfo(
      type: 'dhcp',
      source: 'dhcp_lease',
      ipAddress: lease['address'],
      macAddress: lease['mac-address']?.toUpperCase(),
      hostName: _displayNameFromLease(lease),
      id: lease['.id'],
      isStaticLease: isStatic,
      rawData: rawData,
    );
  }

  int _clientIndexByMacOrIp({String? mac, String? ip}) {
    final normalizedMac = mac?.toUpperCase();
    for (var i = 0; i < _clients.length; i++) {
      final client = _clients[i];
      if (normalizedMac != null &&
          client.macAddress?.toUpperCase() == normalizedMac) {
        return i;
      }
      if (ip != null && client.ipAddress == ip) {
        return i;
      }
    }
    return -1;
  }

  /// بارگذاری IP دستگاه
  Future<void> loadDeviceIp({
    bool forceRefresh = false,
    bool notifyChanges = true,
  }) async {
    if (_deviceIp != null && !_isRefreshing && !forceRefresh) {
      return;
    }

    try {
      String? localIp;
      try {
        localIp = await NetworkInfoService().getDeviceIPv4Address();
      } catch (_) {}

      final routerIp = await _serviceManager.getDeviceIp().timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );

      final resolved = CurrentDevicePolicy.pickBestDeviceIp(
        localIp: localIp,
        routerReportedIp: routerIp,
        clients: _clients,
        routerHost: _serviceManager.currentConnection?.host,
      );
      if (resolved != null && resolved != _deviceIp) {
        _applyResolvedDeviceIdentity(resolved, clients: _clients);
        if (notifyChanges) {
          notifyListeners();
        }
      }
    } catch (_) {
      // Keep the previous IP when detection fails.
    }
  }

  /// بارگذاری اطلاعات روتر (board-name و platform)
  Future<void> loadRouterInfo({bool notifyChanges = true}) async {
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final routerInfo = await _serviceManager.getRouterInfo().timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      if (routerInfo != null) {
        _routerInfo = routerInfo;
        if (notifyChanges) {
          notifyListeners();
        }
      }
    } catch (_) {
      // Router info is optional.
    }
  }

  Future<void> _ensureCurrentDeviceStatic() async {
    if (_isEnsuringCurrentDeviceStatic ||
        !_serviceManager.isConnected ||
        _serviceManager.service == null) {
      return;
    }

    final ip = _deviceIp?.trim();
    if (ip == null || ip.isEmpty || _lastAutoStaticIp == ip) {
      return;
    }

    _isEnsuringCurrentDeviceStatic = true;
    try {
      final success = await _serviceManager
          .makeClientStatic(ipAddress: ip)
          .timeout(_autoStaticTimeout, onTimeout: () => false);
      if (success) {
        _lastAutoStaticIp = ip;
      }
    } catch (_) {
      // Ignore auto-static errors and keep the app responsive.
    } finally {
      _isEnsuringCurrentDeviceStatic = false;
    }
  }

  /// بارگذاری لیست کلاینت‌های متصل
  Future<void> loadClients({
    bool showLoading = true,
    bool notifyChanges = true,
  }) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = '????? ?????? ???? ???. ???? ?????? ???? ????.';
      _isLoading = false;
      _isDataComplete = false;
      if (notifyChanges) {
        notifyListeners();
      }
      return;
    }

    if (showLoading) {
      _isLoading = true;
      _isDataComplete = false;
      _errorMessage = null;
      if (notifyChanges) {
        notifyListeners();
      }
    }

    try {
      final result = await _serviceManager.getConnectedClients().timeout(
        const Duration(seconds: 12),
      );
      final clientsList = (result['clients'] as List)
          .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
          .toList();

      final bannedMacs = <String>{};
      final bannedIps = <String>{};
      for (final banned in _bannedClients) {
        final bannedMac = banned['mac_address']?.toString().toUpperCase();
        final bannedIp = banned['address']?.toString();
        if (bannedMac != null && bannedMac.isNotEmpty) {
          bannedMacs.add(bannedMac);
        }
        if (bannedIp != null && bannedIp.isNotEmpty) {
          bannedIps.add(bannedIp);
        }
      }

      final filteredClientsList = clientsList.where((client) {
        if (!ClientDisplayPolicy.shouldShowInConnectedList(client)) {
          return false;
        }
        final mac = client.macAddress?.toUpperCase();
        final ip = client.ipAddress;
        return (mac == null || !bannedMacs.contains(mac)) &&
            (ip == null || !bannedIps.contains(ip));
      }).toList();

      _clients = filteredClientsList..sort(_compareClientsForDisplay);
      _isDataComplete = true;
      _isLoading = false;
      _errorMessage = null;
      _scheduleTrafficPollForNewClients();
      if (notifyChanges) {
        notifyListeners();
      }
    } catch (e) {
      _errorMessage = '??? ?? ?????? ???? ???????: $e';
      _isLoading = false;
      _isDataComplete = false;
      if (notifyChanges) {
        notifyListeners();
      }
    }
  }

  Future<void> loadBannedClients({bool notifyChanges = true}) async {
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final fastList = await _serviceManager.getBannedClientsFast().timeout(
        _fastCountTimeout,
        onTimeout: () => _bannedClients,
      );
      _applyBannedList(fastList, markLoaded: true);
      if (notifyChanges) {
        notifyListeners();
      }

      unawaited(_enrichBannedClients());
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] banned list failed: $e');
      if (_bannedClients.isEmpty) {
        _bannedListLoaded = true;
        _visibleBannedLimit = 0;
        if (notifyChanges) {
          notifyListeners();
        }
      }
    }
  }

  Future<void> _enrichBannedClients() async {
    if (!_serviceManager.isConnected || _isBannedEnriching) {
      return;
    }
    _isBannedEnriching = true;
    try {
      final current = List<Map<String, dynamic>>.from(_bannedClients);
      final enriched = await _serviceManager.getBannedClients().timeout(
        _bannedClientsTimeout,
        onTimeout: () => current,
      );
      if (enriched.isEmpty && current.isNotEmpty) {
        return;
      }
      _applyBannedList(enriched, markLoaded: true);
      notifyListeners();
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] banned list enrich failed: $e');
    } finally {
      _isBannedEnriching = false;
    }
  }

  Future<void> ensureBannedListLoaded({bool force = false}) async {
    if (force) {
      _bannedListLoaded = false;
    }
    if (_isBannedListLoading) {
      return;
    }
    if (_bannedListLoaded && !force) {
      if (_bannedClients.isNotEmpty) {
        unawaited(_enrichBannedClients());
        return;
      }
      if ((_bannedCountHint ?? 0) == 0) {
        return;
      }
    }

    final showSkeleton = _bannedClients.isEmpty;
    _isBannedListLoading = showSkeleton;
    _bannedListLoadingStartedAt = showSkeleton ? DateTime.now() : null;
    if (showSkeleton) {
      notifyListeners();
    }

    try {
      await loadBannedClients(notifyChanges: true);
    } finally {
      _isBannedListLoading = false;
      _bannedListLoadingStartedAt = null;
      notifyListeners();
    }
  }

  Future<void> _loadPhase1DeviceList({
    bool preserveVisibleWindow = false,
  }) async {
    if (!_serviceManager.isConnected) {
      throw Exception('Connection is not established');
    }

    final previousVisibleLimit = _visibleClientLimit;

    final leases = await _serviceManager.getPhase1BoundDhcpLeases().timeout(
      _phase1Timeout,
      onTimeout: () {
        throw TimeoutException('phase1 dhcp leases');
      },
    );

    _clients = leases.map(_clientFromDhcpLease).toList();
    _filterBannedFromConnectedList();
    _clients.sort(_compareClientsByIpOrder);
    _applyResolvedDeviceIdentity(_deviceIp, clients: _clients);
    _rebuildDisplayCache();
    if (preserveVisibleWindow && previousVisibleLimit > 0) {
      _visibleClientLimit = DeviceListPagination.clampLimit(
        previousVisibleLimit,
        _displayClientsCache.length,
      );
    } else {
      _visibleClientLimit = DeviceListPagination.initialPageSize.clamp(
        1,
        _displayClientsCache.length,
      );
    }
    _seedInitialTrafficViewport();
    _isDataComplete = false;
    _errorMessage = null;
    _scheduleTrafficPollForNewClients();
  }

  Future<void> _loadPhase2StatusEnrichment() async {
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final banRules = await _serviceManager
          .getPhase2ManagedBanRawRules()
          .timeout(
            _phase2StepTimeout,
            onTimeout: () => <Map<String, String>>[],
          );

      final bannedIps = <String>{};
      final bannedMacs = <String>{};
      for (final rule in banRules) {
        final ip = rule['src-address']?.trim();
        final mac = rule['src-mac-address']?.trim().toUpperCase();
        if (ip != null && ip.isNotEmpty) {
          bannedIps.add(ip);
        }
        if (mac != null && mac.isNotEmpty) {
          bannedMacs.add(mac);
        }
      }

      var banDataChanged = false;
      _clients = _clients.map((client) {
        final ip = client.ipAddress;
        final mac = client.macAddress?.toUpperCase();
        final confirmedBanned =
            (ip != null && bannedIps.contains(ip)) ||
            (mac != null && bannedMacs.contains(mac)) ||
            client.rawData['is_banned'] == true;

        if (confirmedBanned != (client.rawData['is_banned'] == true)) {
          banDataChanged = true;
        }

        if (!confirmedBanned) {
          return client;
        }

        final rawData = Map<String, dynamic>.from(client.rawData)
          ..['is_banned'] = true;
        return client.copyWith(rawData: rawData);
      }).toList();

      _filterBannedFromConnectedList();

      if (banDataChanged) {
        notifyListeners();
      }

      final arpEntries = await _serviceManager.getPhase2ArpTable().timeout(
        _phase2StepTimeout,
        onTimeout: () => <Map<String, String>>[],
      );

      final arpCompleteIps = <String>{};
      for (final entry in arpEntries) {
        final ip = (entry['address'] ?? '').trim();
        final isComplete = (entry['complete'] ?? 'false').toString() == 'true';
        if (ip.isNotEmpty && isComplete) {
          arpCompleteIps.add(ip);
        }
      }

      var arpChanged = false;
      for (final arp in arpEntries) {
        final mac = arp['mac-address']?.toUpperCase();
        final ip = arp['address'];
        if (mac == null || ip == null || ip.isEmpty) {
          continue;
        }

        final index = _clientIndexByMacOrIp(mac: mac);
        if (index < 0) {
          continue;
        }

        final client = _clients[index];
        if (client.ipAddress == null || client.ipAddress!.isEmpty) {
          _clients[index] = client.copyWith(
            ipAddress: ip,
            rawData: Map<String, dynamic>.from(client.rawData)
              ..['address'] = ip,
          );
          arpChanged = true;
        }
      }

      if (arpChanged) {
        notifyListeners();
      }

      final neighborEntries = await _serviceManager
          .getPhase2NeighborDiscovery()
          .timeout(
            _phase2StepTimeout,
            onTimeout: () => <Map<String, String>>[],
          );
      _applyNeighborIdentities(neighborEntries);

      final routerInfoForWireless = _routerInfo ?? _serviceManager.routerInfo;
      var wirelessChanged = false;

      if (!ClientDisplayPolicy.shouldSkipWirelessEnrichment(
        routerInfoForWireless,
      )) {
        final wirelessClients = await _serviceManager
            .getPhase2WirelessRegistrations()
            .timeout(
              _phase2StepTimeout,
              onTimeout: () => <Map<String, String>>[],
            );

        for (final wireless in wirelessClients) {
          final mac = wireless['mac-address']?.toUpperCase();
          if (mac == null || mac.isEmpty) {
            continue;
          }

          final signal = wireless['signal-strength'];
          final ssid = wireless['ssid'];
          final lastIp = wireless['last-ip'];
          final index = _clientIndexByMacOrIp(mac: mac);

          if (index >= 0) {
            final client = _clients[index];
            final mergedIp = client.ipAddress ?? lastIp;
            if (!ClientDisplayPolicy.hasValidIp(mergedIp)) {
              continue;
            }
            final rawData = Map<String, dynamic>.from(client.rawData)
              ..addAll(wireless);
            _clients[index] = client.copyWith(
              type: 'wireless',
              ipAddress: mergedIp,
              signalStrength: signal ?? client.signalStrength,
              ssid: ssid ?? client.ssid,
              interface: wireless['interface'] ?? client.interface,
              rawData: rawData,
            );
            wirelessChanged = true;
          } else if (ClientDisplayPolicy.hasValidIp(lastIp) &&
              !_isTargetInBannedLists(ip: lastIp, mac: mac)) {
            final neighborName = _neighborIdentityForMac(mac, neighborEntries);
            final wirelessRawData = Map<String, dynamic>.from(wireless);
            if (neighborName != null) {
              wirelessRawData['identity'] = neighborName;
            }
            _clients.add(
              ClientInfo(
                type: 'wireless',
                source: 'wireless_registration',
                macAddress: mac,
                ipAddress: lastIp,
                hostName: neighborName,
                ssid: ssid,
                signalStrength: signal,
                interface: wireless['interface'],
                rawData: wirelessRawData,
              ),
            );
            wirelessChanged = true;
          }
        }
      } else {
        debugPrint(
          '[CLIENT_LIST] skipping wireless enrichment for CPE/DHCP-only board',
        );
      }

      _filterBannedFromConnectedList();
      _sortClientsForDisplay();
      _isDataComplete = true;

      _applyOnlineStatus(arpCompleteIps: arpCompleteIps);

      if (wirelessChanged || arpChanged) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] Phase 2 failed: $e');
      _sortClientsForDisplay();
      _isDataComplete = true;
      _phase2Complete = true;
    }
  }

  Future<void> _loadPhase3SecondaryData() async {
    try {
      String? localIp;
      try {
        localIp = await NetworkInfoService().getDeviceIPv4Address();
      } catch (_) {}

      final isolated = await _serviceManager
          .loadSecondaryDataIsolated()
          .timeout(_phase3Timeout, onTimeout: () => <String, dynamic>{});

      final deviceIp = CurrentDevicePolicy.pickBestDeviceIp(
        localIp: localIp,
        routerReportedIp: isolated['deviceIp'] as String?,
        clients: _clients,
        routerHost: _serviceManager.currentConnection?.host,
      );
      if (deviceIp != null && deviceIp.isNotEmpty) {
        _applyResolvedDeviceIdentity(deviceIp, clients: _clients);
      } else if (localIp != null && localIp.isNotEmpty) {
        _applyResolvedDeviceIdentity(localIp, clients: _clients);
      }

      final routerInfo = isolated['routerInfo'] as Map<String, dynamic>?;
      if (routerInfo != null) {
        _routerInfo = routerInfo;
        _filterBannedFromConnectedList();
      }

      if (isolated.containsKey('isNewConnectionsLocked')) {
        _isNewConnectionsLocked =
            isolated['isNewConnectionsLocked'] as bool? ?? false;
        _lockStatusCachedAt = DateTime.now();
      }

      if (_clients.isNotEmpty) {
        _sortClientsForDisplay();
      }

      _phase3Complete = true;
      notifyListeners();
      _startOnlineStatusTimer();
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] Phase 3 failed: $e');
    }
  }

  void _applyOnlineStatus({
    required Set<String> arpCompleteIps,
    Map<String, int>? lastSeenByIp,
  }) {
    var anyChanged = false;

    for (var i = 0; i < _clients.length; i++) {
      final device = _clients[i];
      final ip = (device.ipAddress ?? '').trim();

      if (ip.isEmpty || ip == '0.0.0.0') {
        if (device.isOnline != null) {
          _clients[i].isOnline = null;
          anyChanged = true;
        }
        continue;
      }

      final inArpComplete = arpCompleteIps.contains(ip);

      final lastSeenSeconds =
          lastSeenByIp?[ip] ??
          RouterOsDurationParser.toSeconds(
            device.rawData['last-seen']?.toString(),
          );

      final bool? newStatus;
      if (inArpComplete) {
        newStatus = true;
      } else if (lastSeenSeconds != null &&
          lastSeenSeconds > offlineThresholdSeconds) {
        newStatus = false;
      } else {
        newStatus = null;
      }

      if (newStatus != device.isOnline) {
        _clients[i].isOnline = newStatus;
        anyChanged = true;
        final label = newStatus == true
            ? '✅ ONLINE'
            : newStatus == false
            ? '❌ OFFLINE'
            : '❓ UNKNOWN';
        debugPrint(
          '[ONLINE_STATUS] $label ${device.hostName ?? ip} '
          '(last-seen: ${device.rawData['last-seen'] ?? 'n/a'}, arp: $inArpComplete)',
        );
      }
    }

    if (anyChanged) {
      _rebuildDisplayCache();
      notifyListeners();
    }
  }

  void _startOnlineStatusTimer() {
    _onlineStatusTimer?.cancel();
    _onlineStatusTimer = Timer.periodic(
      statusRefreshInterval,
      (_) => _refreshOnlineStatus(),
    );
  }

  void _stopOnlineStatusTimer() {
    _onlineStatusTimer?.cancel();
    _onlineStatusTimer = null;
  }

  void _startTrafficStream() {
    _stopTrafficStream();
    _seedInitialTrafficViewport();
    _trafficStreamCoordinator = TrafficStreamCoordinator(
      onSample: _sampleTrafficRates,
      onRates: _applyTrafficRates,
      shouldContinue: () =>
          _phase1Complete && _clients.isNotEmpty && _serviceManager.isConnected,
    );
    _configureTrafficStream();
    _trafficStreamCoordinator!.start();
    _startTrafficDisplayTimer();
  }

  void _startTrafficDisplayTimer() {
    _trafficDisplayTimer?.cancel();
    _trafficDisplayTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_trafficStore.syncDisplayTick()) {
        notifyListeners();
      }
    });
  }

  void _stopTrafficDisplayTimer() {
    _trafficDisplayTimer?.cancel();
    _trafficDisplayTimer = null;
  }

  ({Set<String> ips, Map<String, String> macToIp}) _trafficTrackingContext() {
    return _trafficStore.trackingContext(_trafficTrackedClients);
  }

  void _configureTrafficStream({int? trackedCount}) {
    final coordinator = _trafficStreamCoordinator;
    if (coordinator == null) {
      return;
    }
    final tracking = _trafficTrackingContext();
    coordinator.configure(
      trackedCount: trackedCount ?? tracking.ips.length,
      usesInstantQueueRates: _serviceManager.trafficUsesInstantQueueRates,
    );
  }

  Future<Map<String, ClientTrafficRate>> _sampleTrafficRates() async {
    if (_trafficPollInProgress ||
        _apiOperationInProgress ||
        !_phase1Complete ||
        _clients.isEmpty ||
        !_serviceManager.isConnected) {
      return {};
    }

    _trafficPollInProgress = true;
    try {
      final tracking = _trafficTrackingContext();
      if (tracking.ips.isEmpty) {
        return {};
      }
      _configureTrafficStream(trackedCount: tracking.ips.length);
      return await _serviceManager.pollTrafficRates(
        trackedIps: tracking.ips,
        macToIp: tracking.macToIp,
      );
    } catch (e) {
      debugPrint('[TRAFFIC] stream sample failed: $e');
      return {};
    } finally {
      _trafficPollInProgress = false;
    }
  }

  void _applyTrafficRates(Map<String, ClientTrafficRate> rates) {
    if (rates.isEmpty) {
      return;
    }
    final tracking = _trafficTrackingContext();
    if (tracking.ips.isEmpty) {
      return;
    }

    final isFirstPoll = !_trafficStore.pollReady;
    final firstMeasurement = _trafficStore.applyPoll(
      trackedIps: tracking.ips,
      samples: rates,
      rateChanged: _trafficRateChanged,
    );
    if (firstMeasurement || isFirstPoll) {
      notifyListeners();
    }
    _armTrafficPlaceholderWatch();
  }

  void _scheduleTrafficPollForNewClients() {
    if (!_phase1Complete) {
      return;
    }
    final tracking = _trafficTrackingContext();
    if (tracking.ips.isEmpty) {
      return;
    }
    if (_trafficStore.newIpsSinceLastPoll(tracking.ips).isEmpty) {
      return;
    }
    _configureTrafficStream(trackedCount: tracking.ips.length);
    if (_trafficStreamCoordinator?.isRunning != true) {
      _startTrafficStream();
    }
  }

  void _stopTrafficStream() {
    _cancelTrafficViewportSyncTimer();
    _stopTrafficDisplayTimer();
    _trafficStreamCoordinator?.stop();
    _trafficStreamCoordinator?.dispose();
    _trafficStreamCoordinator = null;
  }

  Stream<Map<String, ClientTrafficRate>>? get trafficRateStream =>
      _trafficStreamCoordinator?.stream;

  ClientTrafficRate? trafficForIp(String? ip) => _trafficStore.rateFor(ip);

  ClientTrafficRate? trafficForClient(ClientInfo client) =>
      trafficForIp(client.ipAddress);

  bool _trafficRateChanged(int? previous, int? next) {
    if (previous == null && next == null) {
      return false;
    }
    if (previous == null || next == null) {
      return true;
    }
    if (previous == next) {
      return false;
    }
    final delta = (previous - next).abs();
    if (delta <= 1) {
      return false;
    }
    if (previous == 0 || next == 0) {
      return true;
    }
    final peak = previous > next ? previous : next;
    return delta > 100 || delta > peak * 0.02;
  }

  ClientTrafficRate? liveTrafficForIp(String? ip) => trafficForIp(ip);

  void startOnlineStatusTimer() => _startOnlineStatusTimer();

  void stopOnlineStatusTimer() => _stopOnlineStatusTimer();

  Future<void> refreshOnlineStatus() => _refreshOnlineStatus();

  Future<void> _refreshOnlineStatus() async {
    if (_apiOperationInProgress ||
        _isLoading ||
        _isRefreshing ||
        _clients.isEmpty) {
      return;
    }
    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      final arpEntries = await _serviceManager.getArpTable().timeout(
        _onlineRefreshTimeout,
        onTimeout: () => <Map<String, String>>[],
      );
      final leaseLastSeen = await _serviceManager.getDhcpLastSeen().timeout(
        _onlineRefreshTimeout,
        onTimeout: () => <Map<String, String>>[],
      );

      final arpCompleteIps = <String>{};
      for (final entry in arpEntries) {
        if ((entry['complete'] ?? '') == 'true') {
          final ip = (entry['address'] ?? '').trim();
          if (ip.isNotEmpty) {
            arpCompleteIps.add(ip);
          }
        }
      }

      final lastSeenMap = <String, int>{};
      for (final lease in leaseLastSeen) {
        final ip = (lease['address'] ?? '').trim();
        final secs = RouterOsDurationParser.toSeconds(
          lease['last-seen']?.toString(),
        );
        if (ip.isNotEmpty && secs != null) {
          lastSeenMap[ip] = secs;
        }
      }

      var anyChanged = false;

      for (var i = 0; i < _clients.length; i++) {
        final ip = (_clients[i].ipAddress ?? '').trim();
        if (ip.isEmpty || ip == '0.0.0.0') {
          continue;
        }

        final prevOnline = _clients[i].isOnline;
        final inArp = arpCompleteIps.contains(ip);
        final lastSeen =
            lastSeenMap[ip] ??
            RouterOsDurationParser.toSeconds(
              _clients[i].rawData['last-seen']?.toString(),
            );

        final bool? newStatus;
        if (inArp) {
          newStatus = true;
        } else if (lastSeen != null && lastSeen > offlineThresholdSeconds) {
          newStatus = false;
        } else {
          newStatus = null;
        }

        if (newStatus != prevOnline) {
          _clients[i].isOnline = newStatus;
          anyChanged = true;
          debugPrint(
            '[ONLINE_STATUS] Changed: ${_clients[i].hostName ?? ip} '
            '$prevOnline → $newStatus',
          );
        }
      }

      if (anyChanged) {
        _rebuildDisplayCache();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[ONLINE_STATUS] Refresh failed: $e');
    }
  }

  Future<void> _runBackgroundTasks() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_phase3Complete && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    if (!_serviceManager.isConnected) {
      return;
    }

    try {
      await _ensureCurrentDeviceStatic();
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] auto-static failed: $e');
    }

    try {
      if (_serviceManager.service != null) {
        await _serviceManager.service!.checkAndBanBannedDevices().timeout(
          const Duration(seconds: 25),
          onTimeout: () => [],
        );
      }
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] checkAndBanBannedDevices failed: $e');
    }
  }

  Future<void> _runProgressiveLoad() async {
    if (_serviceManager.service == null) {
      _errorMessage = 'اتصال برقرار نشده است. لطفاً دوباره وارد شوید.';
      _isLoading = false;
      _isDataComplete = false;
      notifyListeners();
      return;
    }

    if (!_serviceManager.isConnected) {
      final restored = await _serviceManager.ensureSession();
      if (!restored) {
        _errorMessage = 'اتصال برقرار نشده است. لطفاً دوباره وارد شوید.';
        _isLoading = false;
        _isDataComplete = false;
        notifyListeners();
        return;
      }
    }

    _phase1Complete = false;
    _phase2Complete = false;
    _phase3Complete = false;
    _currentPhase = LoadingPhase.counts;
    _isDataComplete = false;
    _resetPaginationLoadingState();
    _resetConnectedWindow();
    _connectedCountHint = null;
    notifyListeners();

    _stopTrafficStream();
    _trafficStore.reset();
    _serviceManager.beginProgressiveLoad();
    try {
      await _resolveDeviceIdentityEarly();

      unawaited(prefetchTabCounts());
      await _loadPhase1DeviceList();

      _phase1Complete = true;
      _isLoading = false;
      _currentPhase = LoadingPhase.phase2;
      notifyListeners();

      _startTrafficStream();
      _serviceManager.endProgressiveLoad();

      unawaited(_loadPhase2AndFinish());
    } catch (e) {
      final message = e.toString();
      if (message.contains('Timeout') || message.contains('timeout')) {
        _errorMessage =
            'زمان دریافت لیست دستگاه‌ها تمام شد. اتصال را بررسی کنید و دوباره تلاش کنید.';
      } else {
        _errorMessage = message.replaceAll('Exception: ', '');
      }
      debugPrint('[PROGRESSIVE_LOAD] Error: $e');
      _isLoading = false;
      _isDataComplete = false;
      _phase2Complete = true;
      _serviceManager.endProgressiveLoad();
      notifyListeners();
    }
  }

  Future<void> _loadPhase2AndFinish() async {
    try {
      await _loadPhase2StatusEnrichment();
      _phase2Complete = true;
      _isDataComplete = true;
      _currentPhase = LoadingPhase.phase3;
      notifyListeners();

      unawaited(_loadPhase3SecondaryData());
      unawaited(_runBackgroundTasks());
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] Phase 2/3 background failed: $e');
      _phase2Complete = true;
      _isDataComplete = true;
      notifyListeners();
    }
  }

  /// به‌روزرسانی کامل داده‌ها (برای refresh)
  Future<void> refresh() {
    final activeRefresh = _activeRefreshFuture;
    if (activeRefresh != null) {
      return activeRefresh;
    }

    final future = _performRefresh();
    _activeRefreshFuture = future;
    future.whenComplete(() {
      if (identical(_activeRefreshFuture, future)) {
        _activeRefreshFuture = null;
      }
    });
    return future;
  }

  Future<void> _performRefresh() async {
    _isRefreshing = true;
    notifyListeners();

    try {
      await _runProgressiveLoad();
    } catch (e) {
      _errorMessage = 'Refresh failed.';
      debugPrint('[PROGRESSIVE_LOAD] refresh error: $e');
    } finally {
      _isRefreshing = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshConnectedFast() async {
    if (_isLoading || _isRefreshing || !_serviceManager.isConnected) {
      return;
    }
    _isRefreshing = true;
    _resetPaginationLoadingState();
    _phase2Complete = false;
    notifyListeners();
    try {
      unawaited(prefetchTabCounts());
      await _loadPhase1DeviceList(preserveVisibleWindow: true);
      _phase1Complete = true;
      _isLoading = false;
      _currentPhase = LoadingPhase.phase2;
      _startTrafficStream();
      notifyListeners();
      unawaited(_loadPhase2AndFinish());
    } catch (e) {
      debugPrint('[PROGRESSIVE_LOAD] fast refresh failed: $e');
      _phase2Complete = true;
    } finally {
      _isRefreshing = false;
      _isLoadingMoreConnected = false;
      notifyListeners();
    }
  }

  /// Return from device detail / overlay: keep list, Phase2, scroll, and traffic.
  /// Never refetches DHCP or restarts the live-traffic loop.
  void resumeAfterOverlay() {
    if (!_phase1Complete || _clients.isEmpty) {
      return;
    }
    _scheduleTrafficViewportSync();
    if (_trafficStreamCoordinator?.isRunning != true) {
      _startTrafficStream();
      return;
    }
    _configureTrafficStream();
    _scheduleTrafficPollForNewClients();
  }

  Future<void> onHomeTabActivated() async {
    if (!_phase1Complete && !_isLoading && _clients.isEmpty) {
      await initialize();
      return;
    }
    unawaited(prefetchTabCounts());
    if (_phase1Complete) {
      unawaited(refreshOnlineStatus());
      _scheduleTrafficPollForNewClients();
    }
  }

  void _addOptimisticBannedEntry({
    required String ipAddress,
    String? macAddress,
    String? hostname,
  }) {
    final macUpper = macAddress?.toUpperCase();
    final alreadyListed = _bannedClients.any((banned) {
      final bannedIp = banned['address']?.toString();
      final bannedMac = banned['mac_address']?.toString().toUpperCase();
      if (bannedIp == ipAddress) {
        return true;
      }
      return macUpper != null && macUpper.isNotEmpty && bannedMac == macUpper;
    });

    if (alreadyListed) {
      return;
    }

    _bannedClients = [
      ..._bannedClients,
      {
        'address': ipAddress,
        'mac_address': macAddress,
        'host_name': hostname,
        'hostname': hostname,
        'dhcp_blocked': true,
        'wireless_blocked': false,
        'chains': <String>[],
        'rule_ids': <String>[],
      },
    ];
    _bannedListLoaded = true;
    _bannedCountHint = _bannedClients.length;
    _ensureBannedWindowInitialized();
  }

  Future<bool> _applyBanOnRouter({
    required String ipAddress,
    String? macAddress,
    String? hostname,
    String? ssid,
    ClientInfo? removedClient,
    int removedIndex = -1,
  }) async {
    if (!_serviceManager.isConnected || _serviceManager.service == null) {
      return false;
    }

    return _runUserApiOperation(() async {
      try {
        var success = false;
        for (var attempt = 1; attempt <= 2; attempt++) {
          try {
            if (attempt > 1) {
              await _serviceManager.ensureSessionHealthy();
            }
            success = await _serviceManager.service!.banClientWithFingerprint(
              ipAddress,
              macAddress: macAddress,
              hostname: hostname,
              ssid: ssid,
            );
            if (success) {
              break;
            }
          } catch (e) {
            debugPrint('[BAN] attempt $attempt failed: $e');
            success = false;
            if (attempt == 2) {
              rethrow;
            }
          }
        }

        if (!success) {
          success = await _serviceManager.service!.banClient(
            ipAddress,
            macAddress: macAddress,
            comment: 'Banned via Flutter App',
          );
        }

        if (!success) {
          _errorMessage = 'Client ban failed.';
          if (removedClient != null && removedIndex >= 0) {
            _clients.insert(removedIndex, removedClient);
            _removeFromBannedList(ipAddress, macAddress: macAddress);
            _filterBannedFromConnectedList();
          }
          notifyListenersImmediate();
          return false;
        }

        _filterBannedFromConnectedList();
        _errorMessage = null;
        notifyListenersImmediate();
        unawaited(loadBannedClients());
        return true;
      } catch (e) {
        debugPrint('[BAN] router ban failed: $e');
        _errorMessage = 'Error banning client: $e';
        if (removedClient != null && removedIndex >= 0) {
          _clients.insert(removedIndex, removedClient);
          _removeFromBannedList(ipAddress, macAddress: macAddress);
          _filterBannedFromConnectedList();
        }
        notifyListenersImmediate();
        return false;
      }
    });
  }

  /// مسدودسازی سریع از صفحه جزئیات — UI فوری، API در پس‌زمینه.
  Future<bool> banClientFast({
    required String ipAddress,
    String? macAddress,
    String? hostname,
    String? ssid,
  }) async {
    if (ipAddress.isEmpty) {
      return false;
    }

    if (!_serviceManager.isConnected || _serviceManager.service == null) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return false;
    }

    if (_isCurrentDeviceTarget(ipAddress, macAddress: macAddress)) {
      _errorMessage = 'امکان مسدود کردن دستگاه فعلی وجود ندارد.';
      notifyListenersImmediate();
      return false;
    }

    ClientInfo? removedClient;
    var removedIndex = -1;
    if (macAddress != null && macAddress.isNotEmpty) {
      final macUpper = macAddress.toUpperCase();
      removedIndex = _clients.indexWhere(
        (client) =>
            client.macAddress?.toUpperCase() == macUpper ||
            client.ipAddress == ipAddress,
      );
    } else {
      removedIndex = _clients.indexWhere(
        (client) => client.ipAddress == ipAddress,
      );
    }
    if (removedIndex != -1) {
      removedClient = _clients.removeAt(removedIndex);
    }

    _addOptimisticBannedEntry(
      ipAddress: ipAddress,
      macAddress: macAddress,
      hostname: hostname,
    );
    _filterBannedFromConnectedList();
    _errorMessage = null;
    notifyListenersImmediate();

    unawaited(
      _applyBanOnRouter(
        ipAddress: ipAddress,
        macAddress: macAddress,
        hostname: hostname,
        ssid: ssid,
        removedClient: removedClient,
        removedIndex: removedIndex,
      ),
    );
    return true;
  }

  /// مسدود کردن کلاینت به صورت آنی (سریع - الگو از banClient)
  /// این متد فوراً UI را به‌روزرسانی می‌کند و عملیات را در پس‌زمینه انجام می‌دهد
  Future<bool> banClientInstant(String ipAddress, {String? macAddress}) async {
    if (ipAddress.isEmpty) {
      return false;
    }

    _removeClientFromList(ipAddress, macAddress: macAddress);
    notifyListenersImmediate();

    return _applyBanOnRouter(ipAddress: ipAddress, macAddress: macAddress);
  }

  Future<bool> banClient(
    String ipAddress, {
    String? macAddress,
    String? hostname,
    String? ssid,
  }) async {
    if (!_serviceManager.isConnected || _serviceManager.service == null) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return false;
    }

    if (_isCurrentDeviceTarget(ipAddress, macAddress: macAddress)) {
      _errorMessage = 'امکان مسدود کردن دستگاه فعلی وجود ندارد.';
      notifyListenersImmediate();
      return false;
    }

    final operationKey = _operationKeyForClient(
      macAddress: macAddress,
      ipAddress: ipAddress,
    );
    _activeOperationDeviceMac = operationKey;

    ClientInfo? removedClient;
    var removedIndex = -1;
    if (macAddress != null && macAddress.isNotEmpty) {
      final macUpper = macAddress.toUpperCase();
      removedIndex = _clients.indexWhere(
        (client) =>
            client.macAddress?.toUpperCase() == macUpper ||
            client.ipAddress == ipAddress,
      );
    } else {
      removedIndex = _clients.indexWhere(
        (client) => client.ipAddress == ipAddress,
      );
    }
    if (removedIndex != -1) {
      removedClient = _clients.removeAt(removedIndex);
      _addOptimisticBannedEntry(
        ipAddress: ipAddress,
        macAddress: macAddress,
        hostname: hostname,
      );
      _filterBannedFromConnectedList();
      notifyListenersImmediate();
    }

    try {
      return await _runUserApiOperation(() async {
        var success = false;
        try {
          success = await _serviceManager.service!.banClientWithFingerprint(
            ipAddress,
            macAddress: macAddress,
            hostname: hostname,
            ssid: ssid,
          );
        } catch (e) {
          debugPrint('[BAN] fingerprint ban failed: $e');
        }

        if (!success) {
          success = await _serviceManager.service!.banClient(
            ipAddress,
            macAddress: macAddress,
            comment: 'Banned via Flutter App',
          );
        }

        if (!success) {
          _errorMessage = 'Client ban failed.';
          if (removedClient != null && removedIndex >= 0) {
            _clients.insert(removedIndex, removedClient);
            _removeFromBannedList(ipAddress, macAddress: macAddress);
          }
          return false;
        }

        await loadBannedClients(notifyChanges: false);
        _filterBannedFromConnectedList();
        _errorMessage = null;
        return true;
      });
    } catch (e) {
      if (removedClient != null && removedIndex >= 0) {
        _clients.insert(removedIndex, removedClient);
        _removeFromBannedList(ipAddress, macAddress: macAddress);
      }
      _errorMessage = 'Error banning client: $e';
      notifyListenersImmediate();
      return false;
    } finally {
      _activeOperationDeviceMac = null;
    }
  }

  void _removeClientFromList(String ipAddress, {String? macAddress}) {
    if (macAddress != null) {
      final macUpper = macAddress.toUpperCase();
      _clients.removeWhere(
        (client) =>
            client.macAddress?.toUpperCase() == macUpper ||
            client.ipAddress == ipAddress,
      );
      _isDataComplete = true;
      return;
    }

    _clients.removeWhere((client) => client.ipAddress == ipAddress);
    _isDataComplete = true;
  }

  /// بهینه‌سازی: refresh در پس‌زمینه انجام می‌شود تا UI فوراً پاسخ دهد
  String _clientActionKey(ClientInfo client) {
    return client.macAddress?.toUpperCase() ??
        client.ipAddress ??
        client.id ??
        client.hashCode.toString();
  }

  bool isApprovalActionInProgress(ClientInfo client) {
    return _approvalActionsInProgress.contains(_clientActionKey(client));
  }

  bool isDevicePendingApproval(
    ClientInfo client, {
    bool isCurrentDevice = false,
  }) {
    if (isCurrentDevice || client.isStaticLease == true) {
      return false;
    }
    return client.ipAddress != null &&
        (client.isStaticLease == false || client.macAddress != null);
  }

  void _markClientStatic(ClientInfo target) {
    final key = _clientActionKey(target);
    _clients = _clients.map((client) {
      if (_clientActionKey(client) != key) {
        return client;
      }
      final rawData = Map<String, dynamic>.from(client.rawData)
        ..['dynamic'] = 'false'
        ..['is_static_lease'] = true;
      return client.copyWith(isStaticLease: true, rawData: rawData);
    }).toList();
    _sortClientsForDisplay();
  }

  void _updateClientDisplayName(ClientInfo target, String displayName) {
    final key = _clientActionKey(target);
    _clients = _clients.map((client) {
      if (_clientActionKey(client) != key) {
        return client;
      }
      final rawData = Map<String, dynamic>.from(client.rawData)
        ..['host_name'] = displayName
        ..['host-name'] = displayName
        ..['comment'] = displayName;
      return client.copyWith(hostName: displayName, rawData: rawData);
    }).toList()..sort(_compareClientsForDisplay);
  }

  Future<bool> approveDevice(ClientInfo client) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return false;
    }

    final key = _clientActionKey(client);
    if (_approvalActionsInProgress.contains(key)) {
      return false;
    }

    return _runUserApiOperation(() async {
      _approvalActionsInProgress.add(key);
      try {
        final success = await _serviceManager
            .makeClientStatic(
              ipAddress: client.ipAddress,
              macAddress: client.macAddress,
            )
            .timeout(_autoStaticTimeout, onTimeout: () => false);

        if (!success) {
          _errorMessage = 'Make Static failed.';
          return false;
        }

        _markClientStatic(client);
        _errorMessage = null;
        Future.microtask(refresh);
        return true;
      } catch (e) {
        _errorMessage = 'Error approving device: $e';
        return false;
      } finally {
        _approvalActionsInProgress.remove(key);
      }
    });
  }

  Future<bool> rejectDevice(ClientInfo client) async {
    if (client.ipAddress == null || client.ipAddress!.isEmpty) {
      _errorMessage = 'Device IP was not found.';
      notifyListenersImmediate();
      return false;
    }

    final key = _clientActionKey(client);
    if (_approvalActionsInProgress.contains(key)) {
      return false;
    }

    _approvalActionsInProgress.add(key);
    notifyListenersImmediate();
    try {
      // Step 1: make static first (same policy, avoids DHCP race before ban).
      final staticSuccess = await _runUserApiOperation(() async {
        return _serviceManager
            .makeClientStatic(
              ipAddress: client.ipAddress,
              macAddress: client.macAddress,
            )
            .timeout(_autoStaticTimeout, onTimeout: () => false);
      });

      if (!staticSuccess) {
        _errorMessage = 'Make Static failed.';
        notifyListenersImmediate();
        return false;
      }

      _markClientStatic(client);

      // Step 2: ban using the same fast path used by Device Detail screen.
      final banned = await banClientFast(
        ipAddress: client.ipAddress!,
        macAddress: client.macAddress,
        hostname: client.hostName,
        ssid: client.ssid,
      );
      _errorMessage = banned ? null : 'Device ban failed.';
      notifyListenersImmediate();
      return banned;
    } catch (e) {
      _errorMessage = 'Error rejecting device: $e';
      notifyListenersImmediate();
      return false;
    } finally {
      _approvalActionsInProgress.remove(key);
      notifyListenersImmediate();
    }
  }

  Future<void> loadNewConnectionsLockStatus({bool notifyChanges = true}) async {
    if (!_serviceManager.isConnected) {
      _isNewConnectionsLocked = false;
      return;
    }

    if (_lockStatusCachedAt != null &&
        DateTime.now().difference(_lockStatusCachedAt!) < _lockStatusCacheTtl) {
      if (notifyChanges) {
        notifyListeners();
      }
      return;
    }

    try {
      _isNewConnectionsLocked = await _serviceManager
          .isNewConnectionsLocked()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      _lockStatusCachedAt = DateTime.now();
      if (notifyChanges) {
        notifyListeners();
      }
    } catch (_) {
      _isNewConnectionsLocked = false;
    }
  }

  Future<bool> lockNewConnections() async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return false;
    }

    _isLockUpdating = true;
    notifyListenersImmediate();

    return _runUserApiOperation(() async {
      try {
        final success = await _serviceManager.lockNewConnections().timeout(
          const Duration(seconds: 8),
          onTimeout: () => false,
        );
        if (success) {
          _isNewConnectionsLocked = true;
          _errorMessage = null;
        } else {
          _errorMessage = 'Lock New Connections failed.';
        }
        return success;
      } catch (e) {
        _errorMessage = 'Error locking new connections: $e';
        return false;
      } finally {
        _isLockUpdating = false;
      }
    });
  }

  Future<bool> unlockNewConnections() async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return false;
    }

    _isLockUpdating = true;
    notifyListenersImmediate();

    return _runUserApiOperation(() async {
      try {
        final success = await _serviceManager.unlockNewConnections().timeout(
          const Duration(seconds: 8),
          onTimeout: () => false,
        );
        if (success) {
          _isNewConnectionsLocked = false;
          _errorMessage = null;
        } else {
          _errorMessage = 'Unlock New Connections failed.';
        }
        return success;
      } catch (e) {
        _errorMessage = 'Error unlocking new connections: $e';
        return false;
      } finally {
        _isLockUpdating = false;
      }
    });
  }

  Future<bool> toggleNewConnectionsLock() {
    return _isNewConnectionsLocked
        ? unlockNewConnections()
        : lockNewConnections();
  }

  Future<String?> updateClientLeaseDisplayName(
    ClientInfo client,
    String displayName,
  ) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = 'Connection is not established.';
      notifyListenersImmediate();
      return null;
    }

    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty) {
      _errorMessage = 'Device name is required.';
      notifyListenersImmediate();
      return null;
    }

    return _runUserApiOperation(() async {
      try {
        final savedName = await _serviceManager
            .setDhcpLeaseDisplayName(
              ipAddress: client.ipAddress,
              macAddress: client.macAddress,
              displayName: normalizedName,
            )
            .timeout(const Duration(seconds: 20));

        _updateClientDisplayName(client, savedName);
        _errorMessage = null;
        return savedName;
      } catch (e) {
        _errorMessage = 'Error saving device name: $e';
        return null;
      }
    });
  }

  void _addOptimisticConnectedEntry({
    String? ipAddress,
    String? macAddress,
    String? hostname,
    String? ssid,
  }) {
    final normalizedIp = ipAddress?.trim();
    final macUpper = macAddress?.toUpperCase();
    final alreadyListed = _clients.any((client) {
      if (normalizedIp != null &&
          normalizedIp.isNotEmpty &&
          client.ipAddress == normalizedIp) {
        return true;
      }
      return macUpper != null &&
          macUpper.isNotEmpty &&
          client.macAddress?.toUpperCase() == macUpper;
    });
    if (alreadyListed) {
      return;
    }

    _clients.add(
      ClientInfo(
        type: macUpper != null ? 'wireless' : 'dhcp',
        source: 'unban_restore',
        ipAddress: normalizedIp,
        macAddress: macUpper,
        hostName: hostname,
        ssid: ssid,
        rawData: const {
          'is_banned': false,
          'block-access': 'no',
          'dynamic': 'false',
        },
        isStaticLease: true,
      ),
    );
    _sortClientsForDisplay();
  }

  void _removeFromBannedList(String ipAddress, {String? macAddress}) {
    final macUpper = macAddress?.toUpperCase();
    final normalizedIp = ipAddress.trim();
    _bannedClients.removeWhere((banned) {
      final bannedIp = banned['address']?.toString();
      final bannedMac = banned['mac_address']?.toString().toUpperCase();
      if (normalizedIp.isNotEmpty && bannedIp == normalizedIp) {
        return true;
      }
      return macUpper != null && macUpper.isNotEmpty && bannedMac == macUpper;
    });
  }

  Future<bool> unbanClient(
    String ipAddress, {
    String? macAddress,
    String? hostname,
    String? ssid,
  }) async {
    final normalizedIp = ipAddress.trim();
    final normalizedMac = macAddress?.trim().toUpperCase();
    if (normalizedIp.isEmpty &&
        (normalizedMac == null || normalizedMac.isEmpty)) {
      _errorMessage = 'IP یا MAC دستگاه برای رفع مسدودیت لازم است.';
      notifyListenersImmediate();
      return false;
    }

    if (!_serviceManager.isConnected) {
      _errorMessage = 'اتصال برقرار نشده است.';
      notifyListenersImmediate();
      return false;
    }

    final operationKey = _operationKeyForClient(
      macAddress: macAddress,
      ipAddress: ipAddress,
    );
    _activeOperationDeviceMac = operationKey;

    Map<String, dynamic>? bannedSnapshot;
    for (final banned in _bannedClients) {
      final bannedIp = banned['address']?.toString();
      final bannedMac = banned['mac_address']?.toString().toUpperCase();
      if ((normalizedIp.isNotEmpty && bannedIp == normalizedIp) ||
          (normalizedMac != null &&
              normalizedMac.isNotEmpty &&
              bannedMac == normalizedMac)) {
        bannedSnapshot = Map<String, dynamic>.from(banned);
        break;
      }
    }

    _removeFromBannedList(normalizedIp, macAddress: normalizedMac);
    _addOptimisticConnectedEntry(
      ipAddress: normalizedIp.isEmpty ? null : normalizedIp,
      macAddress: normalizedMac,
      hostname:
          hostname ??
          bannedSnapshot?['host_name']?.toString() ??
          bannedSnapshot?['hostname']?.toString(),
      ssid: ssid ?? bannedSnapshot?['ssid']?.toString(),
    );
    notifyListenersImmediate();

    try {
      return await _runUserApiOperation(() async {
        final success =
            await _serviceManager.service
                ?.unbanClientWithFingerprint(
                  normalizedIp,
                  macAddress: normalizedMac,
                  hostname: hostname,
                  ssid: ssid,
                )
                .timeout(_unbanTimeout, onTimeout: () => false) ??
            false;

        if (!success) {
          _errorMessage =
              'رفع مسدودیت کامل نشد. DHCP یا Wireless هنوز مسدود است — دوباره تلاش کنید.';
          if (bannedSnapshot != null) {
            _bannedClients.add(bannedSnapshot);
            if (normalizedIp.isNotEmpty || normalizedMac != null) {
              _removeClientFromList(
                normalizedIp.isEmpty
                    ? (bannedSnapshot['address']?.toString() ?? '')
                    : normalizedIp,
                macAddress: normalizedMac,
              );
            }
          }
          notifyListenersImmediate();
          return false;
        }

        await loadBannedClients(notifyChanges: false);
        _filterBannedFromConnectedList();
        _errorMessage = null;
        return true;
      });
    } catch (e) {
      if (bannedSnapshot != null) {
        _bannedClients.add(bannedSnapshot);
        _removeClientFromList(ipAddress, macAddress: macAddress);
      }
      _errorMessage = 'خطا در رفع مسدودیت کلاینت: $e';
      notifyListenersImmediate();
      return false;
    } finally {
      _activeOperationDeviceMac = null;
    }
  }

  /// تنظیم سرعت کلاینت و به‌روزرسانی state
  Future<bool> setClientSpeed(String target, String maxLimit) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = '????? ?????? ???? ???.';
      notifyListenersImmediate();
      return false;
    }

    return _runUserApiOperation(() async {
      try {
        final success = await _serviceManager.service
            ?.setClientSpeed(target, maxLimit)
            .timeout(_autoStaticTimeout, onTimeout: () => false);

        if (success == true) {
          _errorMessage = null;
          return true;
        }

        _errorMessage = '????? ???? ?????? ???.';
        return false;
      } catch (e) {
        _errorMessage = '??? ?? ????? ????: $e';
        return false;
      }
    });
  }

  Future<bool> removeClientSpeed(String target) async {
    if (!_serviceManager.isConnected) {
      _errorMessage = '????? ?????? ???? ???.';
      notifyListenersImmediate();
      return false;
    }

    return _runUserApiOperation(() async {
      try {
        final success = await _serviceManager.service
            ?.removeClientSpeed(target)
            .timeout(_autoStaticTimeout, onTimeout: () => false);

        if (success == true) {
          _errorMessage = null;
          return true;
        }

        _errorMessage = '???? ??????? ???? ??? ???? ???.';
        return false;
      } catch (e) {
        _errorMessage = '??? ?? ??? ????: $e';
        return false;
      }
    });
  }

  void clear() {
    _stopOnlineStatusTimer();
    _stopTrafficStream();
    unawaited(_serviceManager.disconnectTrafficMonitor());
    _trafficStore.reset();
    _suppressNotifications = false;
    _pendingNotifications = 0;
    _apiOperationInProgress = false;
    _activeOperationDeviceMac = null;
    _isLoading = false;
    _isDataComplete = false;
    _phase1Complete = false;
    _phase2Complete = false;
    _phase3Complete = false;
    _currentPhase = LoadingPhase.idle;
    _bannedListLoaded = false;
    _isBannedListLoading = false;
    _isBannedEnriching = false;
    _bannedListLoadingStartedAt = null;
    _lockStatusCachedAt = null;
    _clients = [];
    _bannedClients = [];
    _connectedCountHint = null;
    _bannedCountHint = null;
    _resetConnectedWindow();
    _resetBannedWindow();
    _errorMessage = null;
    _deviceIp = null;
    _deviceMac = null;
    _isRefreshing = false;
    _routerInfo = null;
    _isNewConnectionsLocked = false;
    _isLockUpdating = false;
    _isEnsuringCurrentDeviceStatic = false;
    _lastAutoStaticIp = null;
    _approvalActionsInProgress.clear();
    notifyListeners();
  }

  Future<bool> isDeviceBanned(String? macAddress, String? ipAddress) async {
    if (macAddress == null && ipAddress == null) {
      return false;
    }

    for (final banned in _bannedClients) {
      final bannedMac = banned['mac_address']?.toString().toUpperCase();
      final bannedIp = banned['address']?.toString();

      if (macAddress != null &&
          bannedMac != null &&
          macAddress.toUpperCase() == bannedMac) {
        return true;
      }

      if (ipAddress != null && bannedIp != null && ipAddress == bannedIp) {
        return true;
      }
    }

    return false;
  }

  Future<void> initialize() async {
    if (_isRefreshing) {
      return;
    }
    if (_isLoading && _phase1Complete) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _runProgressiveLoad();
    } catch (e) {
      _errorMessage = e.toString();
      debugPrint('[PROGRESSIVE_LOAD] initialize error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _stopOnlineStatusTimer();
    _stopTrafficStream();
    unawaited(_serviceManager.disconnectTrafficMonitor());
    _trafficStore.reset();
    super.dispose();
  }
}
