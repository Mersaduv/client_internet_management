import 'dart:io';
import '../models/mikrotik_connection.dart';
import '../models/client_info.dart';
import '../models/device_fingerprint.dart';
import '../services/device_fingerprint_service.dart';
import 'routeros_client_v2.dart' show RouterOSClientV2;
import 'package:shared_preferences/shared_preferences.dart';

/// سرویس برای مدیریت اتصال و عملیات MikroTik RouterOS
/// مشابه endpointهای /api/clients/* در پروژه Python
class MikroTikService {
  RouterOSClientV2? _client;
  MikroTikConnection? _connection;

  /// اتصال به MikroTik RouterOS
  Future<bool> connect(MikroTikConnection connection) async {
    try {
      _connection = connection;
      _client = RouterOSClientV2(
        address: connection.host,
        user: connection.username,
        password: connection.password,
        useSsl: connection.useSsl,
        port: connection.port,
      );

      final success = await _client!.login();
      if (!success) {
        _client = null;
        _connection = null;
      }
      return success;
    } catch (e) {
      _client = null;
      _connection = null;
      throw Exception('خطا در اتصال: $e');
    }
  }

  /// بررسی اتصال
  bool get isConnected => _client?.isConnected ?? false;

  /// بستن اتصال
  void disconnect() {
    _client?.close();
    _client = null;
    _connection = null;
  }

  /// دریافت همه کاربران و دستگاه‌های متصل
  /// مشابه POST /api/clients/all
  Future<Map<String, dynamic>> getAllClients() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final allClients = <ClientInfo>[];

      // 1. Hotspot Active Users
      try {
        final hotspotActive = await _client!.talk(['/ip/hotspot/active/print']);
        for (var user in hotspotActive) {
          allClients.add(ClientInfo(
            type: 'hotspot',
            source: 'hotspot_active',
            user: user['user'],
            ipAddress: user['address'],
            macAddress: user['mac-address'],
            uptime: user['uptime'],
            bytesIn: user['bytes-in'],
            bytesOut: user['bytes-out'],
            loginBy: user['login-by'],
            server: user['server'],
            id: user['.id'],
            rawData: user,
          ));
        }
      } catch (e) {
        // Hotspot ممکن است فعال نباشد
      }

      // 2. Wireless Clients
      try {
        final wirelessClients =
            await _client!.talk(['/interface/wireless/registration-table/print']);
        for (var client in wirelessClients) {
          allClients.add(ClientInfo(
            type: 'wireless',
            source: 'wireless_registration',
            macAddress: client['mac-address'],
            interface: client['interface'],
            ssid: client['ssid'],
            signalStrength: client['signal-strength'],
            uptime: client['uptime'],
            rawData: client,
          ));
        }
      } catch (e) {
        // Wireless ممکن است فعال نباشد
      }

      // 3. DHCP Leases (Bound)
      try {
        final dhcpLeases =
            await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['status']?.toLowerCase() == 'bound') {
            allClients.add(ClientInfo(
              type: 'dhcp',
              source: 'dhcp_lease',
              ipAddress: lease['address'],
              macAddress: lease['mac-address'],
              hostName: lease['host-name'],
              status: lease['status'],
              server: lease['server'],
              expiresAfter: lease['expires-after'],
              id: lease['.id'],
              rawData: lease,
            ));
          }
        }
      } catch (e) {
        // DHCP ممکن است فعال نباشد
      }

      // 4. PPP Active Users
      try {
        final pppActive = await _client!.talk(['/ppp/active/print']);
        for (var user in pppActive) {
          allClients.add(ClientInfo(
            type: 'ppp',
            source: 'ppp_active',
            name: user['name'],
            service: user['service'],
            ipAddress: user['address'],
            uptime: user['uptime'],
            callerId: user['caller-id'],
            bytesIn: user['bytes-in'],
            bytesOut: user['bytes-out'],
            id: user['.id'],
            rawData: user,
          ));
        }
      } catch (e) {
        // PPP ممکن است فعال نباشد
      }

      return {
        'status': 'success',
        'total_count': allClients.length,
        'by_type': {
          'hotspot': allClients.where((c) => c.type == 'hotspot').length,
          'wireless': allClients.where((c) => c.type == 'wireless').length,
          'dhcp': allClients.where((c) => c.type == 'dhcp').length,
          'ppp': allClients.where((c) => c.type == 'ppp').length,
        },
        'clients': allClients.map((c) => c.toMap()).toList(),
      };
    } catch (e) {
      throw Exception('خطا در دریافت لیست کلاینت‌ها: $e');
    }
  }

  /// دریافت جزئیات کامل همه کاربران
  /// مشابه POST /api/clients/detailed
  Future<Map<String, dynamic>> getClientsDetailed() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // دریافت ARP table
      final arpTable = <String, String>{};
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        for (var arp in arpEntries) {
          final ip = arp['address'];
          final mac = arp['mac-address']?.toUpperCase();
          if (ip != null && mac != null) {
            arpTable[ip] = mac;
            arpTable[mac] = ip;
          }
        }
      } catch (e) {
        // ARP ممکن است در دسترس نباشد
      }

      // دریافت Queue information
      final queues = <String, Map<String, String>>{};
      try {
        final queueList = await _client!.talk(['/queue/simple/print']);
        for (var queue in queueList) {
          final target = queue['target'];
          if (target != null) {
            queues[target] = {
              'name': queue['name'] ?? 'N/A',
              'max_limit': queue['max-limit'] ?? 'N/A',
              'bytes': queue['bytes'] ?? '0',
              'packets': queue['packets'] ?? '0',
              'rate': queue['rate'] ?? 'N/A',
            };
          }
        }
      } catch (e) {
        // Queue ممکن است فعال نباشد
      }

      // دریافت همه کلاینت‌ها (مشابه getAllClients)
      final allClientsResult = await getAllClients();
      final clients = (allClientsResult['clients'] as List)
          .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
          .toList();

      // افزودن اطلاعات ARP و Queue
      final enrichedClients = <ClientInfo>[];
      for (var client in clients) {
        var enrichedClient = client;
        var enrichedRawData = Map<String, dynamic>.from(client.rawData);

        if (client.ipAddress != null && arpTable.containsKey(client.ipAddress)) {
          if (client.macAddress == null) {
            enrichedClient = ClientInfo(
              type: client.type,
              source: client.source,
              user: client.user,
              name: client.name,
              ipAddress: client.ipAddress,
              macAddress: arpTable[client.ipAddress],
              hostName: client.hostName,
              uptime: client.uptime,
              bytesIn: client.bytesIn,
              bytesOut: client.bytesOut,
              loginBy: client.loginBy,
              server: client.server,
              id: client.id,
              interface: client.interface,
              ssid: client.ssid,
              signalStrength: client.signalStrength,
              service: client.service,
              callerId: client.callerId,
              status: client.status,
              expiresAfter: client.expiresAfter,
              rawData: enrichedRawData..['arp_mac'] = arpTable[client.ipAddress],
            );
          }
        }

        if (enrichedClient.ipAddress != null && queues.containsKey(enrichedClient.ipAddress)) {
          final queueInfo = queues[enrichedClient.ipAddress]!;
          enrichedRawData = Map<String, dynamic>.from(enrichedClient.rawData);
          enrichedRawData['queue_name'] = queueInfo['name'];
          enrichedRawData['queue_max_limit'] = queueInfo['max_limit'];
          enrichedRawData['queue_bytes'] = queueInfo['bytes'];
          enrichedRawData['queue_packets'] = queueInfo['packets'];
          enrichedRawData['queue_rate'] = queueInfo['rate'];

          enrichedClient = ClientInfo(
            type: enrichedClient.type,
            source: enrichedClient.source,
            user: enrichedClient.user,
            name: enrichedClient.name,
            ipAddress: enrichedClient.ipAddress,
            macAddress: enrichedClient.macAddress,
            hostName: enrichedClient.hostName,
            uptime: enrichedClient.uptime,
            bytesIn: enrichedClient.bytesIn,
            bytesOut: enrichedClient.bytesOut,
            loginBy: enrichedClient.loginBy,
            server: enrichedClient.server,
            id: enrichedClient.id,
            interface: enrichedClient.interface,
            ssid: enrichedClient.ssid,
            signalStrength: enrichedClient.signalStrength,
            service: enrichedClient.service,
            callerId: enrichedClient.callerId,
            status: enrichedClient.status,
            expiresAfter: enrichedClient.expiresAfter,
            rawData: enrichedRawData,
          );
        }

        enrichedClients.add(enrichedClient);
      }

      return {
        'status': 'success',
        'total_count': enrichedClients.length,
        'clients': enrichedClients.map((c) => c.toMap()).toList(),
      };
    } catch (e) {
      throw Exception('خطا در دریافت جزئیات کلاینت‌ها: $e');
    }
  }

  /// دریافت لیست کاربران متصل
  /// مشابه POST /api/clients/connected
  Future<Map<String, dynamic>> getConnectedClients() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final connectedClients = <ClientInfo>[];

      // دریافت DHCP leases برای hostname
      final dhcpLeasesDict = <String, Map<String, String>>{};
      try {
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['status']?.toLowerCase() == 'bound') {
            final mac = lease['mac-address']?.toUpperCase();
            if (mac != null) {
              dhcpLeasesDict[mac] = lease;
            }
          }
        }
      } catch (e) {
        // DHCP ممکن است فعال نباشد
      }

      // دریافت ARP table برای تکمیل اطلاعات IP
      final arpTable = <String, Map<String, String>>{};
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        for (var arp in arpEntries) {
          final mac = arp['mac-address']?.toUpperCase();
          if (mac != null) {
            arpTable[mac] = arp;
          }
        }
      } catch (e) {
        // ARP ممکن است در دسترس نباشد
      }

      // 1. Wireless Clients
      try {
        final wirelessClients =
            await _client!.talk(['/interface/wireless/registration-table/print']);
        for (var client in wirelessClients) {
          final mac = client['mac-address']?.toUpperCase();
          final dhcpInfo = mac != null ? dhcpLeasesDict[mac] : null;
          final arpInfo = mac != null ? arpTable[mac] : null;

          // اولویت: DHCP > ARP
          final ipAddress = dhcpInfo?['address'] ?? arpInfo?['address'];
          final hostName = dhcpInfo?['host-name'];

          connectedClients.add(ClientInfo(
            type: 'wireless',
            source: 'wireless_registration',
            macAddress: mac,
            ipAddress: ipAddress,
            hostName: hostName,
            interface: client['interface'],
            ssid: client['ssid'],
            signalStrength: client['signal-strength'],
            uptime: client['uptime'],
            rawData: client,
          ));
        }
      } catch (e) {
        // Wireless ممکن است فعال نباشد
      }

      // 2. DHCP Leases (Bound) که wireless نیستند
      try {
        final dhcpLeases =
            await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['status']?.toLowerCase() == 'bound') {
            final mac = lease['mac-address']?.toUpperCase();
            // اگر قبلاً به عنوان wireless اضافه نشده
            if (mac != null &&
                !connectedClients.any((c) => c.macAddress?.toUpperCase() == mac)) {
              connectedClients.add(ClientInfo(
                type: 'dhcp',
                source: 'dhcp_lease',
                ipAddress: lease['address'],
                macAddress: mac,
                hostName: lease['host-name'],
                status: lease['status'],
                id: lease['.id'],
                rawData: lease,
              ));
            }
          }
        }
      } catch (e) {
        // DHCP ممکن است فعال نباشد
      }

      // 3. Hotspot Active
      try {
        final hotspotActive = await _client!.talk(['/ip/hotspot/active/print']);
        for (var user in hotspotActive) {
          final ip = user['address'];
          final mac = user['mac-address']?.toUpperCase();
          // اگر قبلاً اضافه نشده
          if (!connectedClients.any((c) =>
              c.ipAddress == ip ||
              (mac != null && c.macAddress?.toUpperCase() == mac))) {
            connectedClients.add(ClientInfo(
              type: 'hotspot',
              source: 'hotspot_active',
              ipAddress: ip,
              macAddress: mac,
              user: user['user'],
              uptime: user['uptime'],
              bytesIn: user['bytes-in'],
              bytesOut: user['bytes-out'],
              id: user['.id'],
              rawData: user,
            ));
          }
        }
      } catch (e) {
        // Hotspot ممکن است فعال نباشد
      }

      return {
        'status': 'success',
        'total_count': connectedClients.length,
        'clients': connectedClients.map((c) => c.toMap()).toList(),
      };
    } catch (e) {
      throw Exception('خطا در دریافت کلاینت‌های متصل: $e');
    }
  }

  /// مسدود کردن کلاینت با استفاده از Device Fingerprint
  /// این تابع Device Fingerprint را محاسبه می‌کند و ذخیره می‌کند
  /// تا حتی با تغییر IP/MAC، دستگاه شناسایی شود
  Future<bool> banClientWithFingerprint(
    String ipAddress, {
    String? macAddress,
    String? hostname,
    String? ssid,
  }) async {
    // ایجاد Device Fingerprint
    final fingerprint = DeviceFingerprint.fromClientInfo(
      ipAddress,
      macAddress,
      hostname,
      ssid,
    );

    // ذخیره Device Fingerprint
    final fingerprintService = DeviceFingerprintService();
    await fingerprintService.saveBannedFingerprint(fingerprint);

    // ایجاد comment با Device Fingerprint
    final fingerprintComment = 'Banned: ${fingerprint.fingerprintId}';
    
    // مسدود کردن با استفاده از banClient اصلی
    return await banClient(
      ipAddress,
      macAddress: macAddress,
      comment: fingerprintComment,
    );
  }

  /// مسدود کردن کلاینت
  /// مشابه POST /api/clients/ban
  /// از Raw rules استفاده می‌کند (بهتر از filter rules برای تعداد زیاد)
  /// از چند بخش مسدود می‌کند:
  /// 1. Firewall Raw Prerouting Chain (بر اساس IP)
  /// 2. Firewall Raw Prerouting Chain (بر اساس MAC - مستقل از IP)
  /// 3. DHCP Block Access
  /// 4. Wireless Access List
  Future<bool> banClient(String ipAddress, {String? macAddress, String? comment}) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // پیدا کردن MAC address از IP اگر داده نشده باشد
      String? macToUse = macAddress;
      if (macToUse == null) {
        try {
          // جستجو در DHCP leases
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            if (lease['address'] == ipAddress) {
              macToUse = lease['mac-address'];
              break;
            }
          }
          
          // اگر در DHCP پیدا نشد، در ARP table جستجو کن
          if (macToUse == null) {
            final arpEntries = await _client!.talk(['/ip/arp/print']);
            for (var arp in arpEntries) {
              if (arp['address'] == ipAddress) {
                macToUse = arp['mac-address'];
                break;
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }

      // بررسی اینکه آیا قبلاً مسدود شده است (بررسی Raw rules)
      try {
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          if (rule['chain'] == 'prerouting' &&
              rule['src-address'] == ipAddress &&
              rule['action'] == 'drop') {
            // قبلاً مسدود شده است
            return true;
          }
        }
      } catch (e) {
        // ignore
      }

      // استفاده از comment داده شده یا comment پیش‌فرض
      final banComment = comment ?? 'Banned via Flutter App';

      // 1. Firewall Raw Prerouting Chain - مسدود کردن ترافیک بر اساس IP
      // Raw rules قبل از connection tracking پردازش می‌شوند و سریع‌تر هستند
      try {
        final rawCommand = ['/ip/firewall/raw/add', '=chain=prerouting', '=src-address=$ipAddress', '=action=drop', '=comment=$banComment - IP'];
        if (macToUse != null) {
          rawCommand.add('=src-mac-address=$macToUse');
        }
        await _client!.talk(rawCommand);
      } catch (e) {
        // ignore - ادامه بده
      }

      // 2. Firewall Raw Prerouting MAC Chain - مسدود کردن بر اساس MAC (مستقل از IP)
      // این rule حتی اگر IP تغییر کند، دستگاه را مسدود می‌کند
      if (macToUse != null) {
        try {
          await _client!.talk([
            '/ip/firewall/raw/add',
            '=chain=prerouting',
            '=src-mac-address=$macToUse',
            '=action=drop',
            '=comment=$banComment - MAC',
          ]);
        } catch (e) {
          // ignore - ادامه بده
        }
      }

      // 3. DHCP Block Access - Block کردن DHCP lease
      if (macToUse != null) {
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            if (leaseMac == macToUse.toUpperCase()) {
              final leaseId = lease['.id'];
              if (leaseId != null) {
                await _client!.talk([
                  '/ip/dhcp-server/lease/set',
                  '=.id=$leaseId',
                  '=block-access=yes',
                ]);
              }
              break;
            }
          }
        } catch (e) {
          // ignore - ادامه بده
        }
      }

      // 4. Wireless Access List - مسدود کردن اتصال وای‌فای
      if (macToUse != null) {
        try {
          // بررسی اینکه آیا MAC قبلاً در access list block شده
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          bool macExists = false;
          for (var acl in accessList) {
            final aclMac = acl['mac-address']?.toString().toUpperCase();
            if (aclMac == macToUse.toUpperCase()) {
              macExists = true;
              // اگر قبلاً block نشده، آن را block کن
              if (acl['action'] != 'reject' && acl['action'] != 'deny') {
                final aclId = acl['.id'];
                if (aclId != null) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/set',
                      '=.id=$aclId',
                      '=action=reject',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
              break;
            }
          }

          // اگر MAC در access list نیست، اضافه کن
          if (!macExists) {
            try {
              await _client!.talk([
                '/interface/wireless/access-list/add',
                '=mac-address=$macToUse',
                '=action=deny',
              ]);
            } catch (e) {
              // اگر deny کار نکرد، reject را امتحان کن
              try {
                await _client!.talk([
                  '/interface/wireless/access-list/add',
                  '=mac-address=$macToUse',
                  '=action=reject',
                ]);
              } catch (e2) {
                // ignore
              }
            }
          }
        } catch (e) {
          // ignore - ادامه بده
        }
      }

      // 5. ایجاد Static IP - برای شناسایی بهتر دستگاه در آینده
      // با Static IP، دستگاه همیشه همان IP را می‌گیرد و شناسایی راحت‌تر می‌شود
      if (macToUse != null) {
        try {
          // پیدا کردن hostname از DHCP lease
          String? hostname;
          try {
            final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
            for (var lease in dhcpLeases) {
              final leaseMac = lease['mac-address']?.toString().toUpperCase();
              if (leaseMac == macToUse.toUpperCase()) {
                hostname = lease['host-name'];
                break;
              }
            }
          } catch (e) {
            // ignore
          }

          await _createOrUpdateStaticLease(
            ipAddress,
            macToUse,
            hostname: hostname,
            comment: '$banComment - Static IP',
          );
        } catch (e) {
          // ignore - ادامه بده
        }
      }

      return true;
    } catch (e) {
      throw Exception('خطا در مسدود کردن کلاینت: $e');
    }
  }

  /// رفع مسدودیت کلاینت با استفاده از Device Fingerprint
  Future<bool> unbanClientWithFingerprint(
    String ipAddress, {
    String? macAddress,
    String? hostname,
    String? ssid,
  }) async {
    // ایجاد Device Fingerprint
    final fingerprint = DeviceFingerprint.fromClientInfo(
      ipAddress,
      macAddress,
      hostname,
      ssid,
    );

    // ابتدا حذف همه rule های firewall مربوط به این Device Fingerprint
    // این اطمینان می‌دهد که rule ها قبل از حذف Device Fingerprint حذف می‌شوند
    try {
      if (_client != null && isConnected) {
        final fingerprintId = fingerprint.fingerprintId;
        
        // حذف همه rule های firewall که comment آن‌ها شامل fingerprintId است
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final ruleComment = rule['comment']?.toString() ?? '';
          if (ruleComment.contains('Auto-banned:') && 
              ruleComment.contains(fingerprintId)) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
              } catch (e) {
                // ignore
              }
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }

    // حذف Device Fingerprint
    final fingerprintService = DeviceFingerprintService();
    await fingerprintService.removeBannedFingerprint(fingerprint);

    // رفع مسدودیت با استفاده از unbanClient اصلی
    final success = await unbanClient(ipAddress, macAddress: macAddress);
    
    // اگر قفل فعال است، دستگاه را به لیست مجاز اضافه کن تا دیگر auto-ban نشود
    if (success) {
      try {
        final isLocked = await isNewConnectionsLocked();
        if (isLocked) {
          // پیدا کردن MAC اگر داده نشده باشد
          String? macToUse = macAddress;
          if (macToUse == null) {
            try {
              final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
              for (var lease in dhcpLeases) {
                if (lease['address'] == ipAddress) {
                  macToUse = lease['mac-address'];
                  break;
                }
              }
              if (macToUse == null) {
                final arpEntries = await _client!.talk(['/ip/arp/print']);
                for (var arp in arpEntries) {
                  if (arp['address'] == ipAddress) {
                    macToUse = arp['mac-address'];
                    break;
                  }
                }
              }
            } catch (e) {
              // ignore
            }
          }
          
          // اضافه کردن به لیست مجاز
          if (macToUse != null || ipAddress.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            
            // اضافه کردن MAC به لیست مجاز
            if (macToUse != null) {
              final allowedMacsList = prefs.getStringList('locked_allowed_macs') ?? [];
              final macUpper = macToUse.toUpperCase();
              if (!allowedMacsList.contains(macUpper)) {
                allowedMacsList.add(macUpper);
                await prefs.setStringList('locked_allowed_macs', allowedMacsList);
              }
            }
            
            // اضافه کردن IP به لیست مجاز
            final allowedIpsList = prefs.getStringList('locked_allowed_ips') ?? [];
            if (!allowedIpsList.contains(ipAddress)) {
              allowedIpsList.add(ipAddress);
              await prefs.setStringList('locked_allowed_ips', allowedIpsList);
            }
            
            // اضافه کردن به wireless access list با action=allow
            if (macToUse != null) {
              try {
                final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
                bool macExists = false;
                for (var acl in accessList) {
                  final aclMac = acl['mac-address']?.toString().toUpperCase();
                  if (aclMac == macToUse.toUpperCase()) {
                    macExists = true;
                    // اگر action allow نیست، آن را allow کن
                    if (acl['action'] != 'allow') {
                      final aclId = acl['.id'];
                      if (aclId != null) {
                        try {
                          await _client!.talk([
                            '/interface/wireless/access-list/set',
                            '=.id=$aclId',
                            '=action=allow',
                            '=comment=Lock New Connections - Allowed Device',
                          ]);
                        } catch (e) {
                          // ignore
                        }
                      }
                    }
                    break;
                  }
                }
                
                // اگر MAC در access list نیست، اضافه کن
                if (!macExists) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/add',
                      '=mac-address=$macToUse',
                      '=action=allow',
                      '=comment=Lock New Connections - Allowed Device',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              } catch (e) {
                // ignore
              }
            }
          }
        }
      } catch (e) {
        // ignore errors - اضافه کردن به لیست مجاز optional است
      }
    }
    
    return success;
  }

  /// رفع مسدودیت کلاینت
  /// مشابه POST /api/clients/unban
  Future<bool> unbanClient(String ipAddress, {String? macAddress}) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // پیدا کردن MAC address از IP اگر داده نشده باشد
      String? macToUse = macAddress;
      if (macToUse == null) {
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            if (lease['address'] == ipAddress) {
              macToUse = lease['mac-address'];
              break;
            }
          }
          if (macToUse == null) {
            final arpEntries = await _client!.talk(['/ip/arp/print']);
            for (var arp in arpEntries) {
              if (arp['address'] == ipAddress) {
                macToUse = arp['mac-address'];
                break;
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }

      int removedCount = 0;

      // 1. حذف Raw Firewall Rules (همه rule های مربوط به این IP/MAC)
      // حذف همه rule های auto-banned و rule های دستی مربوط به این دستگاه
      // شامل rule هایی که فقط IP دارند، فقط MAC دارند، یا هر دو
      // حذف همه rule ها بدون توجه به action یا chain (برای اطمینان از حذف کامل)
      try {
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        final rulesToRemove = <String>[];
        
        for (var rule in rawRules) {
          bool shouldRemove = false;
          final ruleIp = rule['src-address']?.toString();
          final ruleMac = rule['src-mac-address']?.toString();
          
          // بررسی تطابق IP
          if (ruleIp != null && ruleIp.isNotEmpty && ruleIp == ipAddress) {
            shouldRemove = true;
          }
          
          // بررسی تطابق MAC (حتی اگر IP متفاوت باشد)
          if (macToUse != null && ruleMac != null && ruleMac.toUpperCase() == macToUse.toUpperCase()) {
            shouldRemove = true;
          }

          // حذف همه rule های مربوط به این IP/MAC (بدون توجه به comment، action یا chain)
          // این شامل rule های auto-banned (با همه comment های ممکن) و rule های دستی می‌شود
          // comment های auto-banned ممکن است شامل:
          // - "Auto-banned: New connection while locked"
          // - "Auto-banned: New connection while locked - IP"
          // - "Auto-banned: New connection while locked - MAC"
          // - "Banned:" یا "Banned via Flutter App" (مسدود دستی)
          if (shouldRemove) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null && !rulesToRemove.contains(ruleId)) {
              rulesToRemove.add(ruleId);
            }
          }
        }
        
        // حذف همه rule ها
        for (var ruleId in rulesToRemove) {
          try {
            await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
            removedCount++;
          } catch (e) {
            // ignore
          }
        }
      } catch (e) {
        // ignore
      }

      // 2. رفع Block از DHCP Lease و حذف Static Lease (اگر به خاطر ban ایجاد شده)
      // رفع block از همه lease هایی که comment آن‌ها مربوط به auto-banned است یا بدون comment
      // همچنین حذف static lease هایی که به خاطر ban ایجاد شده‌اند (برای auto-banned devices)
      if (macToUse != null) {
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            final leaseIp = lease['address']?.toString();
            if (leaseMac == macToUse.toUpperCase() || leaseIp == ipAddress) {
              final leaseId = lease['.id'];
              final leaseComment = lease['comment']?.toString() ?? '';
              final isStatic = lease['dynamic']?.toString().toLowerCase() == 'false';
              
              // بررسی اینکه آیا این static lease به خاطر auto-ban ایجاد شده است
              // فقط static lease هایی که به خاطر auto-ban ایجاد شده‌اند را حذف می‌کنیم
              // static lease هایی که به خاطر manual ban ایجاد شده‌اند را نگه می‌داریم
              bool isAutoBannedStatic = isStatic && 
                                       leaseComment.contains('Auto-banned: New connection while locked') &&
                                       leaseComment.contains('Static IP');
              
              // اگر static lease به خاطر auto-ban ایجاد شده است، حذف کن (تبدیل به dynamic)
              if (leaseId != null && isAutoBannedStatic) {
                try {
                  await _client!.talk([
                    '/ip/dhcp-server/lease/remove',
                    '=.id=$leaseId',
                  ]);
                  // بعد از حذف، از loop خارج شو (چون lease حذف شده است)
                  break;
                } catch (e) {
                  // ignore
                }
              }
              
              // رفع block از lease (اگر block شده است)
              if (leaseId != null && lease['block-access']?.toString().toLowerCase() == 'yes') {
                try {
                  await _client!.talk([
                    '/ip/dhcp-server/lease/set',
                    '=.id=$leaseId',
                    '=block-access=no',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
              
              if (!isAutoBannedStatic) {
                break;
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }

      // 3. رفع Block از Wireless Access List
      // حذف یا allow کردن همه rule های مربوط به این MAC (بدون توجه به action)
      if (macToUse != null) {
        try {
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          for (var acl in accessList) {
            final aclMac = acl['mac-address']?.toString().toUpperCase();
            if (aclMac == macToUse.toUpperCase()) {
              final aclId = acl['.id'];
              final aclComment = acl['comment']?.toString();
              final aclAction = acl['action']?.toString();
              
              if (aclId != null) {
                try {
                  // اگر action deny یا reject است، باید رفع مسدودیت شود
                  if (aclAction == 'deny' || aclAction == 'reject') {
                    // اگر comment مربوط به قفل است (auto-banned)، حذف کن
                    // اما اگر comment مربوط به مسدود دستی است، فقط action را allow کن (نه حذف)
                    bool isAutoBanned = aclComment != null && 
                                        (aclComment.contains('Auto-banned: New connection while locked') ||
                                         aclComment == 'Lock New Connections - Allowed Device');
                    
                    if (isAutoBanned) {
                      // حذف از access list (auto-banned)
                      await _client!.talk([
                        '/interface/wireless/access-list/remove',
                        '=.id=$aclId',
                      ]);
                    } else {
                      // فقط action را allow کن (مسدود دستی - نباید حذف شود)
                      await _client!.talk([
                        '/interface/wireless/access-list/set',
                        '=.id=$aclId',
                        '=action=allow',
                      ]);
                    }
                  } else if (aclAction == 'allow') {
                    // اگر قبلاً allow است، نیازی به تغییر نیست
                    // اما اگر comment مربوط به قفل است، حذف کن (برای پاکسازی)
                    bool isLockRelated = aclComment != null && 
                                         aclComment == 'Lock New Connections - Allowed Device';
                    if (isLockRelated) {
                      await _client!.talk([
                        '/interface/wireless/access-list/remove',
                        '=.id=$aclId',
                      ]);
                    }
                  }
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }

      // اگر هیچ rule ای حذف نشد اما MAC یا IP وجود دارد، باز هم true برگردان
      // چون ممکن است rule های دیگر (DHCP, Wireless) حذف شده باشند
      if (removedCount > 0 || macToUse != null || ipAddress.isNotEmpty) {
        return true;
      }
      
      return false;
    } catch (e) {
      throw Exception('خطا در رفع مسدودیت کلاینت: $e');
    }
  }

  /// دریافت لیست کلاینت‌های مسدود شده
  /// مشابه POST /api/clients/banned
  /// از Raw firewall rules استفاده می‌کند (بهتر از filter rules برای تعداد زیاد)
  Future<List<Map<String, dynamic>>> getBannedClients() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // پیدا کردن Raw firewall rules با action=drop
      final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
      
      // فیلتر کردن rules با action=drop و chain=prerouting
      final banRules = <Map<String, dynamic>>[];
      for (var rule in rawRules) {
        if (rule['action'] == 'drop' &&
            rule['chain'] == 'prerouting') {
          banRules.add(rule);
        }
      }

      // گروه‌بندی rules بر اساس IP و MAC
      // توجه: ممکن است rule هایی فقط با MAC (بدون IP) وجود داشته باشند
      final ipToRules = <String, Map<String, dynamic>>{};
      final macToRules = <String, Map<String, dynamic>>{};
      
      for (var rule in banRules) {
        final ip = rule['src-address']?.toString();
        final mac = rule['src-mac-address']?.toString();
        
        // اگر IP وجود دارد، بر اساس IP گروه‌بندی کن
        if (ip != null && ip.isNotEmpty) {
          if (!ipToRules.containsKey(ip)) {
            ipToRules[ip] = {
              'address': ip,
              'mac_address': mac,
              'chains': <String>[],
              'rule_ids': <String>[],
              'comment': rule['comment'] ?? '',
            };
          }
          
          final chain = rule['chain']?.toString();
          if (chain != null && !ipToRules[ip]!['chains'].contains(chain)) {
            (ipToRules[ip]!['chains'] as List).add(chain);
          }
          
          final ruleId = rule['.id']?.toString();
          if (ruleId != null && !ipToRules[ip]!['rule_ids'].contains(ruleId)) {
            (ipToRules[ip]!['rule_ids'] as List).add(ruleId);
          }
          
          if (mac != null && ipToRules[ip]!['mac_address'] == null) {
            ipToRules[ip]!['mac_address'] = mac;
          }
        } 
        // اگر فقط MAC وجود دارد (بدون IP)، بر اساس MAC گروه‌بندی کن
        else if (mac != null && mac.isNotEmpty) {
          if (!macToRules.containsKey(mac)) {
            macToRules[mac] = {
              'address': null,
              'mac_address': mac,
              'chains': <String>[],
              'rule_ids': <String>[],
              'comment': rule['comment'] ?? '',
            };
          }
          
          final chain = rule['chain']?.toString();
          if (chain != null && !macToRules[mac]!['chains'].contains(chain)) {
            (macToRules[mac]!['chains'] as List).add(chain);
          }
          
          final ruleId = rule['.id']?.toString();
          if (ruleId != null && !macToRules[mac]!['rule_ids'].contains(ruleId)) {
            (macToRules[mac]!['rule_ids'] as List).add(ruleId);
          }
        }
      }

      // تبدیل به لیست (اول IP-based، سپس MAC-only)
      final bannedClients = <Map<String, dynamic>>[];
      bannedClients.addAll(ipToRules.values);
      
      // برای MAC-only rules، سعی کن IP را از DHCP یا ARP پیدا کن
      for (var macRule in macToRules.values) {
        final mac = macRule['mac_address'] as String?;
        if (mac != null) {
          // بررسی اینکه آیا این MAC قبلاً در لیست IP-based اضافه شده
          bool alreadyAdded = false;
          for (var client in bannedClients) {
            if (client['mac_address']?.toString().toUpperCase() == mac.toUpperCase()) {
              alreadyAdded = true;
              break;
            }
          }
          
          // اگر اضافه نشده، IP را از DHCP یا ARP پیدا کن
          if (!alreadyAdded) {
            String? foundIp;
            try {
              final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
              for (var lease in dhcpLeases) {
                final leaseMac = lease['mac-address']?.toString().toUpperCase();
                if (leaseMac == mac.toUpperCase()) {
                  foundIp = lease['address'];
                  break;
                }
              }
              
              if (foundIp == null) {
                final arpEntries = await _client!.talk(['/ip/arp/print']);
                for (var arp in arpEntries) {
                  final arpMac = arp['mac-address']?.toString().toUpperCase();
                  if (arpMac == mac.toUpperCase()) {
                    foundIp = arp['address'];
                    break;
                  }
                }
              }
            } catch (e) {
              // ignore
            }
            
            macRule['address'] = foundIp;
            bannedClients.add(macRule);
          }
        }
      }

      // بررسی اینکه آیا IP/MAC واقعاً متصل هستند
      // اگر IP/MAC در DHCP leases یا ARP table وجود نداشته باشد،
      // یعنی دستگاه دیگر متصل نیست و نباید در لیست نشان داده شود
      final actuallyConnectedBanned = <Map<String, dynamic>>[];
      
      // دریافت لیست دستگاه‌های واقعاً متصل
      final dhcpLeases = <String, Map<String, dynamic>>{};
      final arpEntries = <String, Map<String, dynamic>>{};
      
      try {
        final leases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in leases) {
          final leaseIp = lease['address']?.toString();
          final leaseMac = lease['mac-address']?.toString();
          if (leaseIp != null) {
            dhcpLeases[leaseIp] = lease;
          }
          if (leaseMac != null) {
            dhcpLeases[leaseMac.toUpperCase()] = lease;
          }
        }
      } catch (e) {
        // ignore
      }
      
      try {
        final arps = await _client!.talk(['/ip/arp/print']);
        for (var arp in arps) {
          final arpIp = arp['address']?.toString();
          final arpMac = arp['mac-address']?.toString();
          if (arpIp != null) {
            arpEntries[arpIp] = arp;
          }
          if (arpMac != null) {
            arpEntries[arpMac.toUpperCase()] = arp;
          }
        }
      } catch (e) {
        // ignore
      }

      // افزودن اطلاعات DHCP و Wireless و بررسی اتصال واقعی
      for (var client in bannedClients) {
        final ip = client['address'] as String?;
        final mac = client['mac_address'] as String?;
        bool isActuallyConnected = false;

        // بررسی اینکه آیا IP/MAC واقعاً متصل است
        if (ip != null && ip.isNotEmpty) {
          // بررسی در DHCP leases
          if (dhcpLeases.containsKey(ip)) {
            final lease = dhcpLeases[ip]!;
            final leaseMac = lease['mac-address']?.toString();
            
            // اگر MAC در rule وجود دارد، باید با MAC در DHCP مطابقت داشته باشد
            if (mac != null && mac.isNotEmpty) {
              if (leaseMac?.toUpperCase() == mac.toUpperCase()) {
                isActuallyConnected = true;
                client['mac_address'] = leaseMac;
              }
            } else {
              // اگر MAC در rule نیست، فقط IP کافی است
              isActuallyConnected = true;
              if (leaseMac != null) {
                client['mac_address'] = leaseMac;
              }
            }
          }
          
          // اگر در DHCP پیدا نشد، در ARP بررسی کن
          if (!isActuallyConnected && arpEntries.containsKey(ip)) {
            final arp = arpEntries[ip]!;
            final arpMac = arp['mac-address']?.toString();
            
            if (mac != null && mac.isNotEmpty) {
              if (arpMac?.toUpperCase() == mac.toUpperCase()) {
                isActuallyConnected = true;
                client['mac_address'] = arpMac;
              }
            } else {
              isActuallyConnected = true;
              if (arpMac != null) {
                client['mac_address'] = arpMac;
              }
            }
          }
        } else if (mac != null && mac.isNotEmpty) {
          // اگر فقط MAC داریم (بدون IP)، بررسی کن که آیا این MAC متصل است
          final macUpper = mac.toUpperCase();
          
          // بررسی در DHCP leases
          for (var lease in dhcpLeases.values) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            if (leaseMac == macUpper) {
              isActuallyConnected = true;
              client['address'] = lease['address'];
              break;
            }
          }
          
          // بررسی در ARP
          if (!isActuallyConnected) {
            for (var arp in arpEntries.values) {
              final arpMac = arp['mac-address']?.toString().toUpperCase();
              if (arpMac == macUpper) {
                isActuallyConnected = true;
                client['address'] = arp['address'];
                break;
              }
            }
          }
        }

        // فقط اگر واقعاً متصل است، به لیست اضافه کن
        if (isActuallyConnected) {
          // بررسی DHCP Block Access
          final finalMac = client['mac_address']?.toString();
          if (finalMac != null) {
            try {
              // استفاده از dhcpLeases که قبلاً لود شده
              if (dhcpLeases.containsKey(finalMac.toUpperCase())) {
                final lease = dhcpLeases[finalMac.toUpperCase()]!;
                client['dhcp_blocked'] = lease['block-access'] == 'yes';
              }
              
              // بررسی Wireless Access List
              final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
              for (var acl in accessList) {
                final aclMac = acl['mac-address']?.toString().toUpperCase();
                if (aclMac == finalMac.toUpperCase()) {
                  client['wireless_blocked'] = acl['action'] == 'reject' || acl['action'] == 'deny';
                  break;
                }
              }
            } catch (e) {
              // ignore
            }
          }
          
          actuallyConnectedBanned.add(client);
        }
      }

      return actuallyConnectedBanned;
    } catch (e) {
      throw Exception('خطا در دریافت لیست مسدود شده‌ها: $e');
    }
  }

  /// تنظیم سرعت کلاینت
  /// مشابه POST /api/clients/set-speed
  /// maxLimit باید به فرمت upload/download باشد (مثال: 10M/10M یا 5000K/2000K)
  Future<bool> setClientSpeed(String target, String maxLimit) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // تبدیل فرمت M/K به بیت بر ثانیه
      String maxLimitInBits = maxLimit;
      if (maxLimit.contains('/')) {
        final parts = maxLimit.split('/');
        if (parts.length == 2) {
          final uploadPart = parts[0].trim();
          final downloadPart = parts[1].trim();
          
          // تبدیل آپلود
          int uploadBits = 0;
          final uploadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(uploadPart);
          if (uploadMatch != null) {
            final value = int.tryParse(uploadMatch.group(1) ?? '0') ?? 0;
            final unit = (uploadMatch.group(2) ?? 'M').toUpperCase();
            if (unit == 'M') {
              uploadBits = value * 1000000; // Mbps به بیت
            } else if (unit == 'K') {
              uploadBits = value * 1000; // Kbps به بیت
            } else {
              uploadBits = value * 1000000; // پیش‌فرض Mbps
            }
          }
          
          // تبدیل دانلود
          int downloadBits = 0;
          final downloadMatch = RegExp(r'^(\d+)([KMkm]?)$').firstMatch(downloadPart);
          if (downloadMatch != null) {
            final value = int.tryParse(downloadMatch.group(1) ?? '0') ?? 0;
            final unit = (downloadMatch.group(2) ?? 'M').toUpperCase();
            if (unit == 'M') {
              downloadBits = value * 1000000; // Mbps به بیت
            } else if (unit == 'K') {
              downloadBits = value * 1000; // Kbps به بیت
            } else {
              downloadBits = value * 1000000; // پیش‌فرض Mbps
            }
          }
          
          maxLimitInBits = '$uploadBits/$downloadBits';
        }
      }

      // پیدا کردن queue موجود با مقایسه IP
      final queues = await _client!.talk(['/queue/simple/print']);
      String? queueId;
      final targetIp = target.split('/')[0].trim();
      
      for (var queue in queues) {
        final queueTarget = queue['target']?.toString() ?? '';
        if (queueTarget.isEmpty) continue;
        
        final queueTargetIp = queueTarget.split('/')[0].trim();
        
        // مقایسه IP ها
        if (queueTargetIp == targetIp || 
            queueTarget == target || 
            queueTarget.startsWith('$targetIp/')) {
          queueId = queue['.id'];
          break;
        }
      }

      // استفاده از IP با /32 برای target
      final targetWithSubnet = target.contains('/') ? target : '$target/32';

      if (queueId != null) {
        // به‌روزرسانی queue موجود
        await _client!.talk(['/queue/simple/set', '=.id=$queueId', '=max-limit=$maxLimitInBits']);
      } else {
        // ایجاد queue جدید
        await _client!.talk(['/queue/simple/add', '=target=$targetWithSubnet', '=max-limit=$maxLimitInBits']);
      }

      // ایجاد Static IP برای شناسایی بهتر دستگاه در آینده
      try {
        // پیدا کردن MAC address از IP
        String? macAddress;
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['address'] == targetIp) {
            macAddress = lease['mac-address'];
            break;
          }
        }
        
        // اگر در DHCP پیدا نشد، در ARP table جستجو کن
        if (macAddress == null) {
          final arpEntries = await _client!.talk(['/ip/arp/print']);
          for (var arp in arpEntries) {
            if (arp['address'] == targetIp) {
              macAddress = arp['mac-address'];
              break;
            }
          }
        }

        if (macAddress != null) {
          await _createOrUpdateStaticLease(
            targetIp,
            macAddress,
            comment: 'Static IP - Speed Limited via Flutter App',
          );
        }
      } catch (e) {
        // ignore errors - Static IP optional است
      }

      return true;
    } catch (e) {
      throw Exception('خطا در تنظیم سرعت: $e');
    }
  }

  /// دریافت سرعت کلاینت
  /// مشابه POST /api/clients/get-speed
  Future<Map<String, String>?> getClientSpeed(String target) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final queues = await _client!.talk(['/queue/simple/print']);
      
      // تبدیل IP به فرمت‌های مختلف برای مقایسه
      final targetIp = target.split('/')[0].trim(); // حذف subnet mask اگر وجود دارد
      
      for (var queue in queues) {
        final queueTarget = queue['target']?.toString() ?? '';
        if (queueTarget.isEmpty) continue;
        
        // استخراج IP از target (ممکن است به صورت 192.168.88.252/32 باشد)
        final queueTargetIp = queueTarget.split('/')[0].trim();
        
        // مقایسه IP ها (با در نظر گرفتن /32)
        if (queueTargetIp == targetIp || 
            queueTarget == target || 
            queueTarget.startsWith('$targetIp/') ||
            queueTargetIp == target) {
          final maxLimit = queue['max-limit']?.toString() ?? '';
          
          // تبدیل از بیت به فرمت M/K
          // در MikroTik، max-limit به بیت بر ثانیه است (نه بایت)
          // مثال: 2000000 = 2 Mbps, 1000000 = 1 Mbps
          String formattedMaxLimit = maxLimit;
          if (maxLimit.isNotEmpty && maxLimit != 'N/A' && maxLimit.contains('/')) {
            final parts = maxLimit.split('/');
            if (parts.length == 2) {
              try {
                // مقدار به بیت بر ثانیه است
                final uploadBits = int.tryParse(parts[0].trim()) ?? 0;
                final downloadBits = int.tryParse(parts[1].trim()) ?? 0;
                
                // تبدیل به Mbps (1 Mbps = 1,000,000 bits)
                final uploadMbps = uploadBits / 1000000;
                final downloadMbps = downloadBits / 1000000;
                
                // اگر کمتر از 1 Mbps باشد، به Kbps تبدیل کن
                String uploadFormatted;
                String downloadFormatted;
                
                if (uploadMbps >= 1) {
                  uploadFormatted = '${uploadMbps.toStringAsFixed(0)}M';
                } else if (uploadBits > 0) {
                  final uploadKbps = uploadBits / 1000;
                  uploadFormatted = '${uploadKbps.toStringAsFixed(0)}K';
                } else {
                  uploadFormatted = '0M';
                }
                
                if (downloadMbps >= 1) {
                  downloadFormatted = '${downloadMbps.toStringAsFixed(0)}M';
                } else if (downloadBits > 0) {
                  final downloadKbps = downloadBits / 1000;
                  downloadFormatted = '${downloadKbps.toStringAsFixed(0)}K';
                } else {
                  downloadFormatted = '0M';
                }
                
                formattedMaxLimit = '$uploadFormatted/$downloadFormatted';
              } catch (e) {
                // اگر تبدیل نشد، همان مقدار اصلی را نگه دار
              }
            }
          }
          
          return {
            'max_limit': formattedMaxLimit,
            'rate': queue['rate']?.toString() ?? 'N/A',
            'bytes': queue['bytes']?.toString() ?? '0',
            'packets': queue['packets']?.toString() ?? '0',
          };
        }
      }
      return null;
    } catch (e) {
      throw Exception('خطا در دریافت سرعت: $e');
    }
  }

  /// دریافت IP دستگاه کاربر
  /// دریافت IP دستگاه کاربر
  /// این تابع سعی می‌کند IP دستگاه کاربر را از طریق چند روش پیدا کند:
  /// 1. استفاده از NetworkInterface برای دریافت IP محلی دستگاه
  /// 2. مقایسه IP محلی با لیست IP های متصل در روتر
  /// 3. استفاده از ARP table و DHCP leases
  Future<String?> getDeviceIp() async {
    if (_client == null || !isConnected) {
      return null;
    }
    
    try {
      // روش 1: استفاده از NetworkInterface برای دریافت IP محلی دستگاه
      String? localDeviceIp;
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: false,
        );
        
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
              final ip = addr.address;
              // بررسی اینکه آیا IP در subnet محلی است (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
              final parts = ip.split('.');
              if (parts.length == 4) {
                final firstOctet = int.tryParse(parts[0]);
                if (firstOctet != null) {
                  if ((firstOctet == 192 && int.tryParse(parts[1]) == 168) ||
                      firstOctet == 10 ||
                      (firstOctet == 172 && 
                       int.tryParse(parts[1]) != null && 
                       int.tryParse(parts[1])! >= 16 && 
                       int.tryParse(parts[1])! <= 31)) {
                    localDeviceIp = ip;
                    break;
                  }
                }
              }
            }
          }
          if (localDeviceIp != null) break;
        }
      } catch (e) {
        // ignore - NetworkInterface ممکن است در برخی پلتفرم‌ها کار نکند
      }
      
      // اگر IP محلی پیدا شد، بررسی می‌کنیم که آیا در روتر هم وجود دارد
      if (localDeviceIp != null) {
        try {
          // بررسی در ARP table
          final arpEntries = await _client!.talk(['/ip/arp/print']);
          for (var arp in arpEntries) {
            if (arp['address']?.toString() == localDeviceIp) {
              return localDeviceIp;
            }
          }
          
          // بررسی در DHCP leases
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            if (lease['address']?.toString() == localDeviceIp) {
              return localDeviceIp;
            }
          }
        } catch (e) {
          // ignore
        }
      }
      
      // روش 2: استفاده از IP روتر برای پیدا کردن subnet و سپس پیدا کردن IP دستگاه
      String? routerIp = _connection?.host;
      if (routerIp != null) {
        try {
          final routerParts = routerIp.split('.');
          if (routerParts.length == 4) {
            final subnetPrefix = '${routerParts[0]}.${routerParts[1]}.${routerParts[2]}.';
            
            // اگر IP محلی در همان subnet است، از آن استفاده می‌کنیم
            if (localDeviceIp != null && localDeviceIp.startsWith(subnetPrefix)) {
              return localDeviceIp;
            }
            
            // پیدا کردن IP در ARP table که در همان subnet است
            final arpEntries = await _client!.talk(['/ip/arp/print']);
            for (var arp in arpEntries) {
              final arpIp = arp['address']?.toString();
              if (arpIp != null && 
                  arpIp.startsWith(subnetPrefix) && 
                  arpIp != routerIp &&
                  arp['dynamic']?.toString().toLowerCase() == 'true') {
                // بررسی در DHCP lease
                try {
                  final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
                  for (var lease in dhcpLeases) {
                    if (lease['address']?.toString() == arpIp &&
                        lease['status']?.toString().toLowerCase() == 'bound') {
                      return arpIp;
                    }
                  }
                } catch (e) {
                  // ignore
                }
                
                return arpIp;
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }
      
      // روش 3: استفاده از DHCP leases (fallback)
      try {
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        // پیدا کردن اولین lease که bound است
        for (var lease in dhcpLeases) {
          final leaseIp = lease['address']?.toString();
          if (leaseIp != null && 
              lease['status']?.toString().toLowerCase() == 'bound') {
            return leaseIp;
          }
        }
      } catch (e) {
        // ignore
      }
      
      // روش 4: استفاده از ARP table (fallback)
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        if (arpEntries.isNotEmpty) {
          // پیدا کردن اولین IP که dynamic است
          for (var arp in arpEntries) {
            final arpIp = arp['address']?.toString();
            if (arpIp != null && 
                arpIp != routerIp &&
                arp['dynamic']?.toString().toLowerCase() == 'true') {
              return arpIp;
            }
          }
          
          // اگر dynamic پیدا نشد، اولین IP را برمی‌گردانیم
          return arpEntries.first['address'];
        }
      } catch (e) {
        // ignore
      }
      
      return null;
    } catch (e) {
      return null;
    }
  }

  /// بررسی و مسدود کردن خودکار دستگاه‌های متصل که Device Fingerprint آن‌ها مسدود شده است
  /// 
  /// این تابع لیست دستگاه‌های متصل را بررسی می‌کند و اگر Device Fingerprint
  /// آن‌ها با لیست مسدود شده‌ها مطابقت داشته باشد، به صورت خودکار مسدود می‌کند.
  /// 
  /// این برای حالتی است که دستگاه با IP/MAC جدید متصل شده اما hostname
  /// یا سایر ویژگی‌های آن تغییر نکرده است.
  Future<List<Map<String, dynamic>>> checkAndBanBannedDevices() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final fingerprintService = DeviceFingerprintService();
      final bannedFingerprints = await fingerprintService.getBannedFingerprints();
      
      if (bannedFingerprints.isEmpty) {
        return [];
      }

      // دریافت لیست دستگاه‌های متصل
      final connectedResult = await getConnectedClients();
      final connectedClients = (connectedResult['clients'] as List)
          .map((c) => ClientInfo.fromMap(c as Map<String, dynamic>))
          .toList();

      final newlyBanned = <Map<String, dynamic>>[];

      // دریافت همه rule های firewall فعلی (یک بار برای همه دستگاه‌ها)
      final existingRules = <String, Map<String, dynamic>>{};
      try {
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final ruleIp = rule['src-address']?.toString();
          final ruleMac = rule['src-mac-address']?.toString();
          final ruleId = rule['.id']?.toString();
          
          if (ruleId != null && 
              rule['action'] == 'drop' && 
              rule['chain'] == 'prerouting') {
            // ذخیره rule بر اساس IP
            if (ruleIp != null && ruleIp.isNotEmpty) {
              existingRules['ip:$ruleIp'] = rule;
            }
            // ذخیره rule بر اساس MAC
            if (ruleMac != null && ruleMac.isNotEmpty) {
              existingRules['mac:${ruleMac.toUpperCase()}'] = rule;
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // بررسی هر دستگاه متصل
      for (var client in connectedClients) {
        // ایجاد Device Fingerprint از ClientInfo
        final clientFingerprint = DeviceFingerprint.fromClientInfo(
          client.ipAddress,
          client.macAddress,
          client.hostName,
          client.ssid,
        );

        // بررسی با لیست مسدود شده‌ها
        // بررسی دو طرفه: clientFingerprint.matches(bannedFingerprint) یا bannedFingerprint.matches(clientFingerprint)
        for (var bannedFingerprint in bannedFingerprints) {
          // بررسی دو طرفه برای اطمینان از تطابق کامل
          bool isMatch = clientFingerprint.matches(bannedFingerprint) || 
                        bannedFingerprint.matches(clientFingerprint);
          
          if (isMatch) {
            // این دستگاه باید مسدود شود
            if (client.ipAddress != null) {
              try {
                // بررسی اینکه آیا دستگاه قبلاً مسدود شده است
                bool alreadyBanned = false;
                
                // بررسی rule های موجود بر اساس IP
                if (client.ipAddress != null) {
                  final ipRule = existingRules['ip:${client.ipAddress}'];
                  if (ipRule != null) {
                    final ruleComment = ipRule['comment']?.toString() ?? '';
                    // اگر comment مربوط به این Device Fingerprint است، قبلاً ban شده
                    if (ruleComment.contains('Auto-banned:') && 
                        ruleComment.contains(bannedFingerprint.fingerprintId)) {
                      alreadyBanned = true;
                    }
                  }
                }
                
                // بررسی rule های موجود بر اساس MAC
                if (!alreadyBanned && client.macAddress != null) {
                  final macRule = existingRules['mac:${client.macAddress!.toUpperCase()}'];
                  if (macRule != null) {
                    final ruleComment = macRule['comment']?.toString() ?? '';
                    // اگر comment مربوط به این Device Fingerprint است، قبلاً ban شده
                    if (ruleComment.contains('Auto-banned:') && 
                        ruleComment.contains(bannedFingerprint.fingerprintId)) {
                      alreadyBanned = true;
                    }
                  }
                }
                
                // اگر قبلاً مسدود نشده، مسدود کن
                if (!alreadyBanned) {
                  await banClient(
                    client.ipAddress!,
                    macAddress: client.macAddress,
                    comment: 'Auto-banned: ${bannedFingerprint.fingerprintId}',
                  );

                  newlyBanned.add({
                    'ip_address': client.ipAddress,
                    'mac_address': client.macAddress,
                    'hostname': client.hostName,
                    'device_type': clientFingerprint.deviceType,
                    'fingerprint_id': clientFingerprint.fingerprintId,
                    'banned_fingerprint_id': bannedFingerprint.fingerprintId,
                  });
                }
              } catch (e) {
                // ignore errors
              }
            }
            break; // اگر پیدا شد، دیگر نیازی به بررسی بقیه نیست
          }
        }
      }

      return newlyBanned;
    } catch (e) {
      throw Exception('خطا در بررسی و مسدود کردن دستگاه‌ها: $e');
    }
  }

  /// دریافت اطلاعات کامل روتر
  /// مشابه POST /api/connect/test در پروژه Python
  /// این اطلاعات شامل uptime, version, board-name, platform, CPU, Memory و ... است
  Future<Map<String, dynamic>> getRouterInfo() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // دریافت اطلاعات از /system/resource/print (همه اطلاعات در یک جا)
      final resource = await _client!.talk(['/system/resource/print']);
      
      if (resource.isEmpty) {
        throw Exception('اطلاعات روتر یافت نشد');
      }

      final resourceData = resource[0];
      
      // دریافت board-name از /system/routerboard/print (اگر موجود باشد)
      String? boardName;
      try {
        final routerboard = await _client!.talk(['/system/routerboard/print']);
        if (routerboard.isNotEmpty) {
          boardName = routerboard[0]['board-name']?.toString();
        }
      } catch (e) {
        // ignore - board-name optional است
      }

      // ساخت Map با تمام اطلاعات
      final routerInfo = <String, dynamic>{
        'uptime': resourceData['uptime']?.toString() ?? 'Unknown',
        'version': resourceData['version']?.toString() ?? 'Unknown',
        'build-time': resourceData['build-time']?.toString() ?? 'Unknown',
        'factory-software': resourceData['factory-software']?.toString() ?? 'Unknown',
        'free-memory': resourceData['free-memory']?.toString() ?? '0',
        'total-memory': resourceData['total-memory']?.toString() ?? '0',
        'cpu': resourceData['cpu']?.toString() ?? 'Unknown',
        'cpu-count': resourceData['cpu-count']?.toString() ?? '0',
        'cpu-frequency': resourceData['cpu-frequency']?.toString() ?? '0',
        'cpu-load': resourceData['cpu-load']?.toString() ?? '0',
        'free-hdd-space': resourceData['free-hdd-space']?.toString() ?? '0',
        'total-hdd-space': resourceData['total-hdd-space']?.toString() ?? '0',
        'write-sect-since-reboot': resourceData['write-sect-since-reboot']?.toString() ?? '0',
        'write-sect-total': resourceData['write-sect-total']?.toString() ?? '0',
        'bad-blocks': resourceData['bad-blocks']?.toString() ?? '0',
        'architecture-name': resourceData['architecture-name']?.toString() ?? 'Unknown',
        'board-name': boardName ?? resourceData['board-name']?.toString() ?? 'Unknown',
        'platform': resourceData['platform']?.toString() ?? 'Unknown',
      };

      return routerInfo;
    } catch (e) {
      throw Exception('خطا در دریافت اطلاعات روتر: $e');
    }
  }

  /// قفل کردن اتصال دستگاه‌های جدید
  /// این تابع از ابتدا مانع اتصال دستگاه‌های جدید می‌شود اما دستگاه‌های قبلاً متصل شده کار می‌کنند
  /// 
  /// روش پیاده‌سازی:
  /// 1. دریافت لیست MAC های فعلی متصل
  /// 2. اضافه کردن MAC دستگاه کاربر به لیست مجاز (برای جلوگیری از مسدود شدن خود کاربر)
  /// 3. برای Wireless: غیرفعال کردن default-authenticate و اضافه کردن MAC های مجاز به access list با action=allow (بقیه deny می‌شوند)
  /// 4. برای LAN: تبدیل leases به static برای حفظ IP های فعلی (برای LAN نمی‌توانیم به راحتی جلوگیری کنیم)
  /// 5. ذخیره لیست MAC ها و IP های مجاز برای بررسی بعدی
  Future<bool> lockNewConnections() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // دریافت لیست MAC های فعلی متصل
      final connectedMacs = <String>{};
      
      // از DHCP leases (bound)
      try {
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['status']?.toString().toLowerCase() == 'bound') {
            final mac = lease['mac-address']?.toString().toUpperCase();
            if (mac != null && mac.isNotEmpty) {
              connectedMacs.add(mac);
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // از Wireless registration table
      try {
        final wirelessClients = await _client!.talk(['/interface/wireless/registration-table/print']);
        for (var client in wirelessClients) {
          final mac = client['mac-address']?.toString().toUpperCase();
          if (mac != null && mac.isNotEmpty) {
            connectedMacs.add(mac);
          }
        }
      } catch (e) {
        // ignore
      }

      // از ARP table (برای دستگاه‌های LAN)
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        for (var arp in arpEntries) {
          final mac = arp['mac-address']?.toString().toUpperCase();
          if (mac != null && mac.isNotEmpty) {
            connectedMacs.add(mac);
          }
        }
      } catch (e) {
        // ignore
      }

      // اضافه کردن MAC دستگاه کاربر به لیست مجاز (برای جلوگیری از مسدود شدن خود کاربر)
      try {
        final deviceIp = await getDeviceIp();
        if (deviceIp != null) {
          bool deviceMacFound = false;
          
          // پیدا کردن MAC دستگاه کاربر از DHCP lease
          try {
            final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
            for (var lease in dhcpLeases) {
              if (lease['address']?.toString() == deviceIp) {
                final mac = lease['mac-address']?.toString().toUpperCase();
                if (mac != null && mac.isNotEmpty) {
                  connectedMacs.add(mac);
                  deviceMacFound = true;
                }
                break;
              }
            }
          } catch (e) {
            // ignore
          }

          // اگر در DHCP پیدا نشد، از ARP table استفاده کن
          if (!deviceMacFound) {
            try {
              final arpEntries = await _client!.talk(['/ip/arp/print']);
              for (var arp in arpEntries) {
                if (arp['address']?.toString() == deviceIp) {
                  final mac = arp['mac-address']?.toString().toUpperCase();
                  if (mac != null && mac.isNotEmpty) {
                    connectedMacs.add(mac);
                    deviceMacFound = true;
                  }
                  break;
                }
              }
            } catch (e) {
              // ignore
            }
          }
        }
      } catch (e) {
        // ignore - اگر نتوانستیم MAC دستگاه کاربر را پیدا کنیم، ادامه بده
      }

      // 1. برای Wireless: جلوگیری از اتصال دستگاه‌های غیرمجاز
      // روش: غیرفعال کردن default-authenticate و فقط MAC های مجاز را allow می‌کنیم
      try {
        final wirelessInterfaces = await _client!.talk(['/interface/wireless/print']);
        
        for (var wifiInterface in wirelessInterfaces) {
          final interfaceName = wifiInterface['name']?.toString();
          final interfaceId = wifiInterface['.id']?.toString();
          
          if (interfaceName != null && interfaceId != null) {
            // غیرفعال کردن default-authenticate
            // این کار باعث می‌شود که فقط MAC هایی که در access list هستند و action=allow دارند، متصل شوند
            // توجه: در MikroTik، وقتی default-authenticate=no است، فقط MAC هایی که rule action=allow دارند می‌توانند متصل شوند
            // MAC هایی که rule ندارند یا rule action=deny/reject دارند، نمی‌توانند متصل شوند
            try {
              // غیرفعال کردن default-authenticate
              await _client!.talk([
                '/interface/wireless/set',
                '=.id=$interfaceId',
                '=default-authenticate=no',
              ]);
            } catch (e) {
              // ignore - ممکن است در برخی نسخه‌ها این تنظیم متفاوت باشد
            }

            // حذف rule های قبلی lock (اگر وجود دارد)
            // و همچنین حذف rule هایی که MAC آن‌ها در لیست مجاز نیست
            final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
            for (var acl in accessList) {
              final comment = acl['comment']?.toString();
              final aclMac = acl['mac-address']?.toString().toUpperCase();
              final aclAction = acl['action']?.toString();
              
              // حذف rule های lock قدیمی
              if (comment == 'Lock New Connections - Allowed Device' || 
                  comment == 'Static Device - Lock Allowed') {
                final aclId = acl['.id'];
                if (aclId != null) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/remove',
                      '=.id=$aclId',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
              
              // حذف rule های allow که MAC آن‌ها در لیست مجاز نیست
              // این برای اطمینان از حذف دستگاه‌هایی است که non-static شده‌اند
              if (aclMac != null && aclAction == 'allow' && 
                  !connectedMacs.contains(aclMac)) {
                final aclId = acl['.id'];
                if (aclId != null) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/remove',
                      '=.id=$aclId',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
            }

            // اضافه کردن MAC های مجاز به access list با action=allow
            // فقط این MAC ها می‌توانند به وای‌فای متصل شوند
            // توجه: در MikroTik access list، rule ها می‌توانند interface مشخص داشته باشند یا نباشند
            // اگر interface مشخص نشده باشد، rule برای همه interface ها اعمال می‌شود
            // ما interface را مشخص می‌کنیم تا rule فقط برای این interface اعمال شود
            for (var mac in connectedMacs) {
              try {
                // بررسی اینکه آیا قبلاً اضافه شده (هم با interface و هم بدون interface)
                bool exists = false;
                String? existingAclId;
                final currentAccessList = await _client!.talk(['/interface/wireless/access-list/print']);
                for (var acl in currentAccessList) {
                  final aclMac = acl['mac-address']?.toString().toUpperCase();
                  final aclInterface = acl['interface']?.toString();
                  
                  // اگر MAC مطابقت دارد و (interface مطابقت دارد یا interface مشخص نشده)
                  if (aclMac == mac && 
                      (aclInterface == null || aclInterface == interfaceName)) {
                    exists = true;
                    existingAclId = acl['.id'];
                    
                    // اگر action allow نیست یا comment مطابقت ندارد، تغییر بده
                    if (acl['action']?.toString() != 'allow' ||
                        acl['comment']?.toString() != 'Lock New Connections - Allowed Device') {
                      if (existingAclId != null) {
                        await _client!.talk([
                          '/interface/wireless/access-list/set',
                          '=.id=$existingAclId',
                          '=action=allow',
                          '=comment=Lock New Connections - Allowed Device',
                          '=interface=$interfaceName',
                        ]);
                      }
                    } else if (aclInterface != interfaceName && existingAclId != null) {
                      // اگر interface مطابقت ندارد، interface را به‌روزرسانی کن
                      await _client!.talk([
                        '/interface/wireless/access-list/set',
                        '=.id=$existingAclId',
                        '=interface=$interfaceName',
                      ]);
                    }
                    break;
                  }
                }
                
                // اگر وجود ندارد، اضافه کن
                if (!exists) {
                  await _client!.talk([
                    '/interface/wireless/access-list/add',
                    '=interface=$interfaceName',
                    '=mac-address=$mac',
                    '=action=allow',
                    '=comment=Lock New Connections - Allowed Device',
                  ]);
                }
              } catch (e) {
                // ignore errors for individual MACs
              }
            }
          }
        }
      } catch (e) {
        // ignore - wireless ممکن است فعال نباشد
      }

      // 2. برای LAN: تبدیل leases به static برای حفظ IP های فعلی
      // این کار باعث می‌شود که دستگاه‌های فعلی IP خود را حفظ کنند
      // اما برای جلوگیری کامل از اتصال جدید، از Wireless Access List استفاده می‌شود
      // توجه: برای LAN (سیمی) نمی‌توانیم به راحتی از اتصال جلوگیری کنیم
      // اما با تبدیل به static، کنترل بهتری داریم
      try {
        final currentLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        
        // تبدیل فقط leases مربوط به MAC های مجاز به static
        // این کار باعث می‌شود که دستگاه‌های فعلی IP خود را حفظ کنند
        for (var lease in currentLeases) {
          if (lease['status']?.toString().toLowerCase() == 'bound') {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            // فقط اگر MAC در لیست مجاز است، تبدیل به static کن
            if (leaseMac != null && connectedMacs.contains(leaseMac)) {
              final leaseId = lease['.id'];
              if (leaseId != null) {
                try {
                  // تبدیل به static lease (فقط برای حفظ IP - تغییر نمی‌دهد)
                  await _client!.talk([
                    '/ip/dhcp-server/lease/make-static',
                    '=.id=$leaseId',
                  ]);
                } catch (e) {
                  // ignore - ممکن است قبلاً static باشد
                }
              }
            }
          }
        }
      } catch (e) {
        // ignore - DHCP ممکن است فعال نباشد
      }

      // 3. جلوگیری از اتصال MAC های غیرمجاز از ابتدا
      // استفاده از Wireless Access List و DHCP Lease Restrictions
      // این روش امن‌تر است و دستگاه‌های فعلی را تحت تأثیر قرار نمی‌دهد
      // به جای استفاده از rule block کلی که ممکن است دستگاه‌های فعلی را block کند،
      // فقط MAC های مجاز را allow می‌کنیم و بقیه به صورت پیش‌فرض deny می‌شوند

      // 4. دریافت و ذخیره IP های همه دستگاه‌های فعلی (شامل دستگاه کاربر) برای جلوگیری از مسدود شدن
      final allowedIps = <String>{};
      
      // اضافه کردن IP دستگاه کاربر
      try {
        final deviceIp = await getDeviceIp();
        if (deviceIp != null) {
          allowedIps.add(deviceIp);
        }
      } catch (e) {
        // ignore
      }
      
      // اضافه کردن IP های همه دستگاه‌های فعلی از DHCP leases
      try {
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['status']?.toString().toLowerCase() == 'bound') {
            final ip = lease['address']?.toString();
            if (ip != null && ip.isNotEmpty) {
              allowedIps.add(ip);
            }
          }
        }
      } catch (e) {
        // ignore
      }
      
      // اضافه کردن IP های همه دستگاه‌های فعلی از ARP table
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        for (var arp in arpEntries) {
          final ip = arp['address']?.toString();
          if (ip != null && ip.isNotEmpty) {
            allowedIps.add(ip);
          }
        }
      } catch (e) {
        // ignore
      }
      
      // اضافه کردن IP های همه دستگاه‌های فعلی از Wireless registration table
      try {
        final wirelessClients = await _client!.talk(['/interface/wireless/registration-table/print']);
        for (var client in wirelessClients) {
          final ip = client['last-ip']?.toString();
          if (ip != null && ip.isNotEmpty) {
            allowedIps.add(ip);
          }
        }
      } catch (e) {
        // ignore
      }

      // 5. ذخیره لیست MAC ها و IP های مجاز در SharedPreferences برای بررسی بعدی
      // این برای بررسی در loadClients استفاده می‌شود
      try {
        final prefs = await SharedPreferences.getInstance();
        // ذخیره لیست MAC های مجاز
        final allowedMacsList = connectedMacs.toList();
        await prefs.setStringList('locked_allowed_macs', allowedMacsList);
        
        // ذخیره لیست IP های مجاز (شامل IP دستگاه کاربر)
        final allowedIpsList = allowedIps.toList();
        await prefs.setStringList('locked_allowed_ips', allowedIpsList);
        
        // ذخیره timestamp برای بررسی بعدی
        await prefs.setInt('locked_timestamp', DateTime.now().millisecondsSinceEpoch);
      } catch (e) {
        // ignore - SharedPreferences optional است
      }

      // 6. آزاد کردن دستگاه‌هایی که به خاطر قفل قبلی مسدود شده‌اند
      // فقط دستگاه‌هایی که comment آن‌ها دقیقاً "Auto-banned: New connection while locked" است
      // دستگاه‌هایی که دستی مسدود شده‌اند (با comment "Banned:" یا "Banned via Flutter App") آزاد نمی‌شوند
      // دستگاه‌هایی که به خاطر Device Fingerprint مسدود شده‌اند (با comment "Auto-banned: [fingerprint]") نیز آزاد نمی‌شوند
      try {
        // حذف rule های firewall که مربوط به قفل قبلی هستند
        // حذف همه rule های auto-banned که مربوط به قفل هستند (با همه comment های ممکن)
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final ruleComment = rule['comment']?.toString() ?? '';
          
          // بررسی اینکه آیا comment مربوط به قفل است (نه Device Fingerprint یا مسدود دستی)
          // comment های مربوط به قفل: "Auto-banned: New connection while locked" یا هر comment که شامل این متن باشد
          // comment های مربوط به Device Fingerprint: "Auto-banned: [fingerprint]" یا "Banned: [fingerprint]"
          // comment های مربوط به مسدود دستی: "Banned via Flutter App" یا "Banned: [fingerprint]"
          bool isLockBan = ruleComment.contains('Auto-banned: New connection while locked') ||
                          ruleComment.contains('New connection while locked');
          
          // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
          bool isManualBan = ruleComment.startsWith('Banned:') ||
                           ruleComment.startsWith('Banned via Flutter App') ||
                           (ruleComment.contains('fingerprint') && 
                            !ruleComment.contains('New connection while locked'));
          
          // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، حذف کن
          if (isLockBan && !isManualBan &&
              rule['action'] == 'drop' &&
              rule['chain'] == 'prerouting') {
            final ruleId = rule['.id'];
            if (ruleId != null) {
              try {
                await _client!.talk([
                  '/ip/firewall/raw/remove',
                  '=.id=$ruleId',
                ]);
              } catch (e) {
                // ignore
              }
            }
          }
        }
        
        // رفع block از DHCP leases که به خاطر قفل block شده‌اند
        // حذف block از همه leases که comment آن‌ها مربوط به قفل است
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            if (lease['block-access']?.toString().toLowerCase() == 'yes') {
              final leaseComment = lease['comment']?.toString() ?? '';
              
              // بررسی اینکه آیا comment مربوط به قفل است
              bool isLockBan = leaseComment.contains('Auto-banned: New connection while locked') ||
                              leaseComment.contains('New connection while locked');
              
              // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
              bool isManualBan = leaseComment.startsWith('Banned:') ||
                               leaseComment.startsWith('Banned via Flutter App') ||
                               (leaseComment.contains('fingerprint') && 
                                !leaseComment.contains('New connection while locked'));
              
              // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، unblock کن
              if (isLockBan && !isManualBan) {
                final leaseId = lease['.id'];
                if (leaseId != null) {
                  try {
                    await _client!.talk([
                      '/ip/dhcp-server/lease/set',
                      '=.id=$leaseId',
                      '=block-access=no',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
        
        // حذف rule های wireless که به خاطر قفل deny/reject شده‌اند
        // حذف همه rule هایی که comment آن‌ها مربوط به قفل است
        try {
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          for (var acl in accessList) {
            final aclComment = acl['comment']?.toString() ?? '';
            final aclAction = acl['action']?.toString();
            
            // اگر action deny یا reject است و comment مربوط به قفل است، حذف کن
            // rule هایی که comment آن‌ها "Banned:" است را نگه دار (مسدود دستی)
            if ((aclAction == 'deny' || aclAction == 'reject')) {
              // بررسی اینکه آیا comment مربوط به قفل است
              bool isLockBan = aclComment.contains('Auto-banned: New connection while locked') ||
                              aclComment.contains('New connection while locked');
              
              // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
              bool isManualBan = aclComment.startsWith('Banned:') ||
                               aclComment.startsWith('Banned via Flutter App') ||
                               (aclComment.contains('fingerprint') && 
                                !aclComment.contains('New connection while locked'));
              
              // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، حذف کن
              if (isLockBan && !isManualBan) {
                final aclId = acl['.id'];
                if (aclId != null) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/remove',
                      '=.id=$aclId',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
      } catch (e) {
        // ignore
      }
      
      // 7. حذف rule های firewall که IP دستگاه‌های فعلی (شامل دستگاه کاربر) را مسدود می‌کنند
      // این برای اطمینان از اینکه IP دستگاه‌های فعلی مسدود نشده‌اند
      // اما فقط rule هایی که مربوط به قفل هستند (نه مسدود دستی)
      try {
        // بررسی و حذف rule های firewall که IP دستگاه‌های فعلی را مسدود می‌کنند
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final ruleIp = rule['src-address']?.toString();
          final ruleComment = rule['comment']?.toString();
          
          // اگر rule مربوط به IP یکی از دستگاه‌های فعلی است و comment مربوط به lock است، حذف کن
          // rule هایی که comment آن‌ها "Banned:" یا "Banned via Flutter App" است را نگه دار
          if (ruleIp != null && 
              allowedIps.contains(ruleIp) &&
              ruleComment != null) {
            // بررسی اینکه آیا comment مربوط به قفل است
            bool isLockBan = ruleComment == 'Auto-banned: New connection while locked' ||
                            ruleComment == 'Auto-banned: New connection while locked - IP' ||
                            ruleComment == 'Auto-banned: New connection while locked - MAC';
            
            // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، حذف کن
            if (isLockBan && 
                !ruleComment.startsWith('Banned:') &&
                !ruleComment.startsWith('Banned via Flutter App') &&
                !ruleComment.contains('fingerprint')) {
              final ruleId = rule['.id'];
              if (ruleId != null) {
                try {
                  await _client!.talk([
                    '/ip/firewall/raw/remove',
                    '=.id=$ruleId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // 8. ذخیره marker در system identity
      try {
        // استفاده از system identity برای ذخیره marker
        final identity = await _client!.talk(['/system/identity/print']);
        if (identity.isNotEmpty) {
          final currentName = identity[0]['name']?.toString() ?? '';
          // اضافه کردن marker به identity (اگر وجود ندارد)
          if (!currentName.contains('[LOCKED_NEW_CONN]')) {
            final originalName = currentName.replaceAll(' [LOCKED_NEW_CONN]', '');
            await _client!.talk([
              '/system/identity/set',
              '=name=$originalName [LOCKED_NEW_CONN]',
            ]);
          }
        }
      } catch (e) {
        // ignore - marker optional است
      }

      return true;
    } catch (e) {
      throw Exception('خطا در قفل کردن اتصال جدید: $e');
    }
  }

  /// رفع قفل اتصال دستگاه‌های جدید
  Future<bool> unlockNewConnections() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // 1. برگرداندن default-authenticate به حالت پیش‌فرض و حذف rule های wireless access list مربوط به lock
      try {
        // برگرداندن default-authenticate و default-forwarding به حالت پیش‌فرض
        final wirelessInterfaces = await _client!.talk(['/interface/wireless/print']);
        for (var wifiInterface in wirelessInterfaces) {
          final interfaceId = wifiInterface['.id']?.toString();
          if (interfaceId != null) {
            try {
              // برگرداندن default-authenticate به yes
              await _client!.talk([
                '/interface/wireless/set',
                '=.id=$interfaceId',
                '=default-authenticate=yes',
              ]);
              
              // برگرداندن default-forwarding به yes (اگر تنظیم شده بود)
              try {
                await _client!.talk([
                  '/interface/wireless/set',
                  '=.id=$interfaceId',
                  '=default-forwarding=yes',
                ]);
              } catch (e) {
                // ignore - ممکن است در برخی نسخه‌ها این تنظیم متفاوت باشد
              }
            } catch (e) {
              // ignore - ممکن است در برخی نسخه‌ها این تنظیم متفاوت باشد
            }
          }
        }

        // حذف rule های access list مربوط به lock
        final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
        for (var acl in accessList) {
          final comment = acl['comment']?.toString();
          if (comment == 'Lock New Connections - Allowed Device') {
            final aclId = acl['.id'];
            if (aclId != null) {
              try {
                await _client!.talk([
                  '/interface/wireless/access-list/remove',
                  '=.id=$aclId',
                ]);
              } catch (e) {
                // ignore
              }
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // 2. حذف Raw rules مربوط به lock (در حال حاضر استفاده نمی‌شود، اما برای اطمینان)
      // توجه: در پیاده‌سازی جدید، از Raw rules استفاده نمی‌کنیم
      // اما این بخش برای پاکسازی rule های قدیمی (اگر وجود داشته باشند) نگه داشته شده
      try {
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final comment = rule['comment']?.toString();
          if (comment == 'Lock New Connections - Allow MAC' ||
              comment == 'Lock New Connections - Block New MACs') {
            final ruleId = rule['.id'];
            if (ruleId != null) {
              try {
                await _client!.talk([
                  '/ip/firewall/raw/remove',
                  '=.id=$ruleId',
                ]);
              } catch (e) {
                // ignore
              }
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // 3. پاک کردن لیست MAC ها و IP های مجاز از SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('locked_allowed_macs');
        await prefs.remove('locked_allowed_ips');
        await prefs.remove('locked_timestamp');
      } catch (e) {
        // ignore
      }

      // 4. بازگرداندن system identity به حالت عادی
      try {
        final identity = await _client!.talk(['/system/identity/print']);
        if (identity.isNotEmpty) {
          final currentName = identity[0]['name']?.toString() ?? '';
          if (currentName.contains('[LOCKED_NEW_CONN]')) {
            final originalName = currentName.replaceAll(' [LOCKED_NEW_CONN]', '');
            await _client!.talk([
              '/system/identity/set',
              '=name=$originalName',
            ]);
          }
        }
      } catch (e) {
        // ignore
      }

      // 5. رفع مسدودیت خودکار دستگاه‌هایی که به خاطر قفل مسدود شده‌اند
      // حذف همه rule های auto-banned که مربوط به قفل هستند (با همه comment های ممکن)
      // دستگاه‌هایی که دستی مسدود شده‌اند (با comment "Banned:" یا "Banned via Flutter App") آزاد نمی‌شوند
      // دستگاه‌هایی که به خاطر Device Fingerprint مسدود شده‌اند (با comment "Auto-banned: [fingerprint]") نیز آزاد نمی‌شوند
      // توجه: دستگاه‌های auto-banned نباید به static تبدیل شوند - فقط unblock می‌شوند
      try {
        // حذف rule های firewall که مربوط به قفل هستند
        final rawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (var rule in rawRules) {
          final ruleComment = rule['comment']?.toString() ?? '';
          
          // بررسی اینکه آیا comment مربوط به قفل است (نه Device Fingerprint یا مسدود دستی)
          // comment های مربوط به قفل: "Auto-banned: New connection while locked" یا هر comment که شامل این متن باشد
          // comment های مربوط به Device Fingerprint: "Auto-banned: [fingerprint]" یا "Banned: [fingerprint]"
          // comment های مربوط به مسدود دستی: "Banned via Flutter App" یا "Banned: [fingerprint]"
          bool isLockBan = ruleComment.contains('Auto-banned: New connection while locked') ||
                          ruleComment.contains('New connection while locked');
          
          // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
          bool isManualBan = ruleComment.startsWith('Banned:') ||
                           ruleComment.startsWith('Banned via Flutter App') ||
                           (ruleComment.contains('fingerprint') && 
                            !ruleComment.contains('New connection while locked'));
          
          // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، حذف کن
          if (isLockBan && !isManualBan &&
              rule['action'] == 'drop' &&
              rule['chain'] == 'prerouting') {
            final ruleId = rule['.id'];
            if (ruleId != null) {
              try {
                await _client!.talk([
                  '/ip/firewall/raw/remove',
                  '=.id=$ruleId',
                ]);
              } catch (e) {
                // ignore
              }
            }
          }
        }
        
        // رفع block از DHCP leases و حذف Static leases که به خاطر قفل ایجاد شده‌اند
        // دستگاه‌های auto-banned نباید به static تبدیل شوند - فقط unblock می‌شوند
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            final leaseComment = lease['comment']?.toString() ?? '';
            final isStatic = lease['dynamic']?.toString().toLowerCase() == 'false';
            final isBlocked = lease['block-access']?.toString().toLowerCase() == 'yes';
            
            // بررسی اینکه آیا comment مربوط به قفل است
            bool isLockBan = leaseComment.contains('Auto-banned: New connection while locked') ||
                            leaseComment.contains('New connection while locked');
            
            // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
            bool isManualBan = leaseComment.startsWith('Banned:') ||
                             leaseComment.startsWith('Banned via Flutter App') ||
                             (leaseComment.contains('fingerprint') && 
                              !leaseComment.contains('New connection while locked'));
            
            // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی
            if (isLockBan && !isManualBan) {
              final leaseId = lease['.id'];
              if (leaseId != null) {
                // اگر static lease است که به خاطر auto-ban ایجاد شده، حذف کن (نباید static باشد)
                if (isStatic && leaseComment.contains('Static IP')) {
                  try {
                    await _client!.talk([
                      '/ip/dhcp-server/lease/remove',
                      '=.id=$leaseId',
                    ]);
                    continue; // بعد از حذف، به lease بعدی برو
                  } catch (e) {
                    // ignore
                  }
                }
                
                // رفع block از lease (اگر block شده است)
                if (isBlocked) {
                  try {
                    await _client!.talk([
                      '/ip/dhcp-server/lease/set',
                      '=.id=$leaseId',
                      '=block-access=no',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
        
        // حذف rule های wireless که به خاطر قفل deny/reject شده‌اند
        // حذف همه rule هایی که comment آن‌ها مربوط به قفل است
        try {
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          for (var acl in accessList) {
            final aclComment = acl['comment']?.toString() ?? '';
            final aclAction = acl['action']?.toString();
            
            // اگر action deny یا reject است و comment مربوط به قفل است، حذف کن
            // rule هایی که comment آن‌ها "Banned:" است را نگه دار (مسدود دستی)
            if ((aclAction == 'deny' || aclAction == 'reject')) {
              // بررسی اینکه آیا comment مربوط به قفل است
              bool isLockBan = aclComment.contains('Auto-banned: New connection while locked') ||
                              aclComment.contains('New connection while locked');
              
              // بررسی اینکه آیا comment مربوط به Device Fingerprint یا مسدود دستی است
              bool isManualBan = aclComment.startsWith('Banned:') ||
                               aclComment.startsWith('Banned via Flutter App') ||
                               (aclComment.contains('fingerprint') && 
                                !aclComment.contains('New connection while locked'));
              
              // اگر مربوط به قفل است و نه Device Fingerprint یا مسدود دستی، حذف کن
              if (isLockBan && !isManualBan) {
                final aclId = acl['.id'];
                if (aclId != null) {
                  try {
                    await _client!.talk([
                      '/interface/wireless/access-list/remove',
                      '=.id=$aclId',
                    ]);
                  } catch (e) {
                    // ignore
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
      } catch (e) {
        // ignore
      }

      return true;
    } catch (e) {
      throw Exception('خطا در رفع قفل اتصال جدید: $e');
    }
  }

  /// بررسی وضعیت قفل اتصال جدید
  Future<bool> isNewConnectionsLocked() async {
    if (_client == null || !isConnected) {
      return false;
    }

    try {
      // بررسی marker در system identity
      final identity = await _client!.talk(['/system/identity/print']);
      if (identity.isNotEmpty) {
        final currentName = identity[0]['name']?.toString() ?? '';
        if (currentName.contains('[LOCKED_NEW_CONN]')) {
          return true;
        }
      }

      // بررسی وجود rule های lock در wireless access list
      final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
      for (var acl in accessList) {
        final comment = acl['comment']?.toString();
        if (comment == 'Lock New Connections - Allowed Device') {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// دریافت لیست MAC های مجاز برای قفل (از SharedPreferences)
  /// این لیست MAC های دستگاه‌هایی است که در زمان فعال شدن قفل متصل بودند
  Future<Set<String>> getAllowedMacsForLock() async {
    final allowedMacs = <String>{};
    
    try {
      // دریافت از SharedPreferences (لیست اولیه در زمان فعال شدن قفل)
      final prefs = await SharedPreferences.getInstance();
      final allowedMacsList = prefs.getStringList('locked_allowed_macs');
      if (allowedMacsList != null) {
        for (var mac in allowedMacsList) {
          if (mac.isNotEmpty) {
            allowedMacs.add(mac.toUpperCase());
          }
        }
      }
    } catch (e) {
      // ignore
    }

    return allowedMacs;
  }

  /// دریافت لیست IP های مجاز برای قفل (از SharedPreferences)
  /// این لیست IP های دستگاه‌هایی است که در زمان فعال شدن قفل متصل بودند (شامل IP دستگاه کاربر)
  Future<Set<String>> getAllowedIpsForLock() async {
    final allowedIps = <String>{};
    
    try {
      // دریافت از SharedPreferences (لیست اولیه در زمان فعال شدن قفل)
      final prefs = await SharedPreferences.getInstance();
      final allowedIpsList = prefs.getStringList('locked_allowed_ips');
      if (allowedIpsList != null) {
        for (var ip in allowedIpsList) {
          if (ip.isNotEmpty) {
            allowedIps.add(ip);
          }
        }
      }
    } catch (e) {
      // ignore
    }

    return allowedIps;
  }

  /// بررسی IP
  /// مشابه POST /api/clients/check-ip
  Future<Map<String, dynamic>> checkIp(String ipAddress) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final result = <String, dynamic>{
        'ip': ipAddress,
        'found': false,
      };

      // بررسی در ARP
      try {
        final arpEntries = await _client!.talk(['/ip/arp/print']);
        for (var arp in arpEntries) {
          if (arp['address'] == ipAddress) {
            result['found'] = true;
            result['mac_address'] = arp['mac-address'];
            result['interface'] = arp['interface'];
            break;
          }
        }
      } catch (e) {
        // ARP ممکن است در دسترس نباشد
      }

      // بررسی در DHCP leases
      try {
        final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
        for (var lease in dhcpLeases) {
          if (lease['address'] == ipAddress) {
            result['found'] = true;
            result['mac_address'] = lease['mac-address'];
            result['host_name'] = lease['host-name'];
            result['status'] = lease['status'];
            break;
          }
        }
      } catch (e) {
        // DHCP ممکن است فعال نباشد
      }

      return result;
    } catch (e) {
      throw Exception('خطا در بررسی IP: $e');
    }
  }

  /// ایجاد یا به‌روزرسانی Static IP Lease
  /// این تابع یک Static DHCP lease ایجاد می‌کند تا دستگاه همیشه همان IP را بگیرد
  /// این برای شناسایی بهتر دستگاه در آینده مفید است
  Future<void> _createOrUpdateStaticLease(
    String ipAddress,
    String macAddress, {
    String? hostname,
    String? comment,
  }) async {
    if (_client == null || !isConnected) {
      return;
    }

    try {
      // بررسی اینکه آیا Static lease قبلاً وجود دارد
      final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
      String? existingLeaseId;
      
      for (var lease in dhcpLeases) {
        final leaseMac = lease['mac-address']?.toString().toUpperCase();
        final leaseIp = lease['address']?.toString();
        
        // اگر MAC یا IP مطابقت دارد
        if (leaseMac == macAddress.toUpperCase() || leaseIp == ipAddress) {
          existingLeaseId = lease['.id'];
          break;
        }
      }

      final staticComment = comment ?? 'Static IP via Flutter App';
      final leaseCommand = <String>[
        '=address=$ipAddress',
        '=mac-address=$macAddress',
        '=comment=$staticComment',
      ];

      if (hostname != null && hostname.isNotEmpty) {
        leaseCommand.add('=host-name=$hostname');
      }

      if (existingLeaseId != null) {
        // به‌روزرسانی lease موجود
        leaseCommand.insert(0, '/ip/dhcp-server/lease/set');
        leaseCommand.insert(1, '=.id=$existingLeaseId');
        await _client!.talk(leaseCommand);
      } else {
        // ایجاد lease جدید
        leaseCommand.insert(0, '/ip/dhcp-server/lease/add');
        await _client!.talk(leaseCommand);
      }
    } catch (e) {
      // ignore errors - Static IP optional است
    }
  }

  /// بررسی اینکه آیا DHCP lease دستگاه static است یا نه
  Future<bool> isDeviceStatic(String? ipAddress, String? macAddress) async {
    if (_client == null || !isConnected) {
      return false;
    }

    if (ipAddress == null && macAddress == null) {
      return false;
    }

    try {
      final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
      for (var lease in dhcpLeases) {
        final leaseMac = lease['mac-address']?.toString().toUpperCase();
        final leaseIp = lease['address']?.toString();
        final isStatic = lease['dynamic']?.toString().toLowerCase() == 'false';

        // بررسی تطابق MAC یا IP
        if ((macAddress != null && leaseMac == macAddress.toUpperCase()) ||
            (ipAddress != null && leaseIp == ipAddress)) {
          return isStatic;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// تبدیل دستگاه به static یا non-static
  /// وقتی static می‌شود: به لیست مجاز اضافه می‌شود (Access List، Static Lease)
  /// وقتی non-static می‌شود: از همه جا حذف می‌شود (Access List، Static Lease حذف می‌شود)
  Future<bool> setDeviceStaticStatus(
    String ipAddress,
    String? macAddress, {
    String? hostname,
    bool isStatic = true,
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // پیدا کردن MAC address از IP اگر داده نشده باشد
      String? macToUse = macAddress;
      if (macToUse == null) {
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            if (lease['address']?.toString() == ipAddress) {
              macToUse = lease['mac-address']?.toString();
              break;
            }
          }

          if (macToUse == null) {
            final arpEntries = await _client!.talk(['/ip/arp/print']);
            for (var arp in arpEntries) {
              if (arp['address']?.toString() == ipAddress) {
                macToUse = arp['mac-address']?.toString();
                break;
              }
            }
          }
        } catch (e) {
          // ignore
        }
      }

      if (macToUse == null) {
        throw Exception('MAC address پیدا نشد');
      }

      if (isStatic) {
        // تبدیل به static: اضافه کردن به لیست مجاز

        // 1. تبدیل DHCP lease به static
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          String? leaseId;
          for (var lease in dhcpLeases) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            final leaseIp = lease['address']?.toString();
            if (leaseMac == macToUse.toUpperCase() || leaseIp == ipAddress) {
              leaseId = lease['.id'];
              break;
            }
          }

          if (leaseId != null) {
            // تبدیل به static lease
            try {
              await _client!.talk([
                '/ip/dhcp-server/lease/make-static',
                '=.id=$leaseId',
              ]);
            } catch (e) {
              // ممکن است قبلاً static باشد - ignore
            }
          } else {
            // اگر lease وجود ندارد، یک static lease جدید ایجاد کن
            await _createOrUpdateStaticLease(
              ipAddress,
              macToUse,
              hostname: hostname,
              comment: 'Static Device - Lock Allowed',
            );
          }
        } catch (e) {
          // ignore - DHCP ممکن است فعال نباشد
        }

        // 2. اضافه کردن به Wireless Access List (اگر wireless است)
        try {
          final wirelessInterfaces = await _client!.talk(['/interface/wireless/print']);
          for (var wifiInterface in wirelessInterfaces) {
            final interfaceName = wifiInterface['name']?.toString();
            if (interfaceName != null) {
              // بررسی اینکه آیا قبلاً اضافه شده
              bool exists = false;
              final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
              for (var acl in accessList) {
                if (acl['mac-address']?.toString().toUpperCase() == macToUse.toUpperCase() &&
                    acl['interface']?.toString() == interfaceName) {
                  exists = true;
                  // اگر action allow نیست، تغییر بده
                  if (acl['action']?.toString() != 'allow') {
                    final aclId = acl['.id'];
                    if (aclId != null) {
                      await _client!.talk([
                        '/interface/wireless/access-list/set',
                        '=.id=$aclId',
                        '=action=allow',
                        '=comment=Static Device - Lock Allowed',
                      ]);
                    }
                  }
                  break;
                }
              }

              // اگر وجود ندارد، اضافه کن
              if (!exists) {
                await _client!.talk([
                  '/interface/wireless/access-list/add',
                  '=interface=$interfaceName',
                  '=mac-address=$macToUse',
                  '=action=allow',
                  '=comment=Static Device - Lock Allowed',
                ]);
              }
            }
          }
        } catch (e) {
          // ignore - wireless ممکن است فعال نباشد
        }

        // 3. اضافه کردن به لیست مجاز در SharedPreferences
        try {
          final prefs = await SharedPreferences.getInstance();
          final allowedMacsList = prefs.getStringList('locked_allowed_macs') ?? [];
          final macUpper = macToUse.toUpperCase();
          if (!allowedMacsList.contains(macUpper)) {
            allowedMacsList.add(macUpper);
            await prefs.setStringList('locked_allowed_macs', allowedMacsList);
          }

          final allowedIpsList = prefs.getStringList('locked_allowed_ips') ?? [];
          if (!allowedIpsList.contains(ipAddress)) {
            allowedIpsList.add(ipAddress);
            await prefs.setStringList('locked_allowed_ips', allowedIpsList);
          }
        } catch (e) {
          // ignore - SharedPreferences optional است
        }
      } else {
        // تبدیل به non-static: حذف از همه جا

        // 1. حذف Static DHCP lease (تبدیل به dynamic با حذف lease)
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            final leaseIp = lease['address']?.toString();
            final isStatic = lease['dynamic']?.toString().toLowerCase() == 'false';

            if (isStatic && (leaseMac == macToUse.toUpperCase() || leaseIp == ipAddress)) {
              final leaseId = lease['.id'];
              if (leaseId != null) {
                // حذف static lease (تبدیل به dynamic)
                try {
                  await _client!.talk([
                    '/ip/dhcp-server/lease/remove',
                    '=.id=$leaseId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        } catch (e) {
          // ignore - DHCP ممکن است فعال نباشد
        }

        // 2. حذف از Wireless Access List
        // حذف همه rule های access list که مربوط به این MAC هستند و action=allow دارند
        // (rule های ban با action=deny/reject را نگه داریم)
        try {
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          for (var acl in accessList) {
            final aclMac = acl['mac-address']?.toString().toUpperCase();
            final aclAction = acl['action']?.toString();
            final aclComment = acl['comment']?.toString() ?? '';
            
            // اگر MAC مطابقت دارد و action=allow است، حذف کن
            // همچنین rule هایی با comment مربوط به static/lock را هم حذف کن
            // اما rule های ban (action=deny/reject بدون comment مربوط به lock) را نگه دار
            if (aclMac == macToUse.toUpperCase() && 
                (aclAction == 'allow' || 
                 aclComment == 'Static Device - Lock Allowed' ||
                 aclComment == 'Lock New Connections - Allowed Device')) {
              final aclId = acl['.id'];
              if (aclId != null) {
                try {
                  await _client!.talk([
                    '/interface/wireless/access-list/remove',
                    '=.id=$aclId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        } catch (e) {
          // ignore - wireless ممکن است فعال نباشد
        }

        // 3. حذف Static ARP entries (اگر وجود داشته باشد)
        try {
          final arpEntries = await _client!.talk(['/ip/arp/print']);
          for (var arp in arpEntries) {
            final arpMac = arp['mac-address']?.toString().toUpperCase();
            final arpIp = arp['address']?.toString();
            final isStatic = arp['dynamic']?.toString().toLowerCase() == 'false';

            if (isStatic && (arpMac == macToUse.toUpperCase() || arpIp == ipAddress)) {
              final arpId = arp['.id'];
              if (arpId != null) {
                try {
                  await _client!.talk([
                    '/ip/arp/remove',
                    '=.id=$arpId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        } catch (e) {
          // ignore - ARP ممکن است فعال نباشد
        }

        // 4. حذف Simple Queue rules (اگر وجود داشته باشد)
        try {
          final queues = await _client!.talk(['/queue/simple/print']);
          for (var queue in queues) {
            final queueTarget = queue['target']?.toString();
            final queueDst = queue['dst']?.toString();
            final queueComment = queue['comment']?.toString() ?? '';

            // اگر IP یا MAC در target/dst است و comment مربوط به static/lock است، حذف کن
            if ((queueTarget == ipAddress || queueTarget == macToUse ||
                 queueDst == ipAddress || queueDst == macToUse) &&
                (queueComment.contains('Static Device') || 
                 queueComment.contains('Lock Allowed'))) {
              final queueId = queue['.id'];
              if (queueId != null) {
                try {
                  await _client!.talk([
                    '/queue/simple/remove',
                    '=.id=$queueId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
            }
          }
        } catch (e) {
          // ignore - Queue ممکن است فعال نباشد
        }

        // 5. قطع Connection Tracking entries (برای قطع اتصال فوری)
        // توجه: Connection entries خودکار expire می‌شوند، اما برای قطع فوری، از firewall drop استفاده می‌کنیم
        // در MikroTik، نمی‌توان connection entries را مستقیماً حذف کرد، اما با حذف rule های allow
        // و حذف DHCP lease، اتصال قطع می‌شود

        // 6. حذف از لیست مجاز در SharedPreferences
        try {
          final prefs = await SharedPreferences.getInstance();
          final allowedMacsList = prefs.getStringList('locked_allowed_macs') ?? [];
          final macUpper = macToUse.toUpperCase();
          if (allowedMacsList.contains(macUpper)) {
            allowedMacsList.remove(macUpper);
            await prefs.setStringList('locked_allowed_macs', allowedMacsList);
          }

          final allowedIpsList = prefs.getStringList('locked_allowed_ips') ?? [];
          if (allowedIpsList.contains(ipAddress)) {
            allowedIpsList.remove(ipAddress);
            await prefs.setStringList('locked_allowed_ips', allowedIpsList);
          }
        } catch (e) {
          // ignore - SharedPreferences optional است
        }
      }

      return true;
    } catch (e) {
      throw Exception('خطا در تبدیل دستگاه: $e');
    }
  }
}

