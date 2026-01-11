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
      // اما قوانین فیلترینگ شبکه‌های اجتماعی را حذف می‌کنیم
      // (comment شامل "Block social" یا "SM-Filter" یا dst-address-list مربوط به شبکه‌های اجتماعی)
      final banRules = <Map<String, dynamic>>[];
      for (var rule in rawRules) {
        final comment = rule['comment']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        
        // بررسی اینکه آیا این rule مربوط به فیلتر شبکه‌های اجتماعی است
        bool isSocialMediaFilter = false;
        
        // بررسی comment
        if (comment.isNotEmpty) {
          final commentLower = comment.toLowerCase();
          if (commentLower.contains('block social') ||
              commentLower.contains('sm-filter') ||
              commentLower.contains('social media') ||
              commentLower.contains('platform=') ||
              commentLower.contains('platform-') ||
              commentLower.contains('platforms=') ||
              commentLower.contains('platforms-')) {
            isSocialMediaFilter = true;
          }
        }
        
        // بررسی dst-address-list (Address-List مربوط به شبکه‌های اجتماعی)
        if (dstAddressList == 'Blocked-Social' || 
            dstAddressList == 'Blocked-Social-IP' ||
            dstAddressList.toLowerCase().contains('social')) {
          isSocialMediaFilter = true;
        }
        
        // اگر rule مربوط به فیلتر شبکه‌های اجتماعی است، آن را نادیده بگیر
        if (isSocialMediaFilter) {
          continue;
        }
        
        // فقط rules با action=drop و chain=prerouting که مربوط به ban هستند
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
          final comment = rule['comment']?.toString() ?? '';
          
          // اگر comment شامل "Block social" است، این یک قانون فیلترینگ شبکه‌های اجتماعی است، نه ban
          if (comment.contains('Block social')) {
            continue;
          }
          
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

  /// مسدود کردن شبکه‌های اجتماعی با استفاده از روش چندلایه (برای اپلیکیشن‌های موبایل)
  /// این متد شامل: DNS Redirect + Address List + DNS Filtering + Firewall Rules + Blocking DNS خارجی + Blocking DoH/DoT + Blocking VPN
  Future<Map<String, dynamic>> blockSocialMediaWithAddressList({
    required List<String> platforms,
    required String deviceIp,
    String? deviceMac,
    String? deviceName,
    String? addressListName, // اگر null باشد، برای هر دستگاه جداگانه ایجاد می‌شود
    bool enableDNSRedirect = true, // اجباری کردن DNS داخلی
    bool blockExternalDNS = true, // بلاک DNS خارجی (device-specific)
    bool blockDoHDoT = true, // بلاک DoH/DoT (device-specific)
    bool blockVPN = true, // بلاک VPN (device-specific)
    bool enableDNSStatic = true, // DNS static entries
    bool enableAddressList = true, // ایجاد Address List با IPهای resolve شده
    bool enableFirewallRule = true, // ایجاد Firewall Rule برای device-specific
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final results = <String, dynamic>{};
      final errors = <Map<String, dynamic>>[];

      // 0. فعال‌سازی DNS سرور روتر
      if (enableDNSRedirect) {
        try {
          await _enableDNSServer();
          results['dns_server'] = 'enabled';
        } catch (e) {
          errors.add({
            'type': 'dns_server',
            'error': e.toString(),
          });
        }
      }

      // 1. DNS Redirect (اجباری کردن استفاده از DNS داخلی) - فقط برای این دستگاه
      // توجه: DNS Redirect برای همه دستگاه‌ها ایجاد نمی‌شود تا تداخل ایجاد نکند
      // فقط DNS Static Entries استفاده می‌شود که برای همه دستگاه‌ها اعمال می‌شود
      // اما فیلترینگ با Address List + Firewall Rules device-specific است
      int dnsRedirectRules = 0;
      // DNS Redirect را غیرفعال می‌کنیم تا تداخل ایجاد نکند
      // به جای آن، فقط از DNS Static Entries استفاده می‌کنیم
      // results['dns_redirect'] = 'disabled - using DNS Static only';
      // dnsRedirectRules = 0;

      // 2. ایجاد Address List دینامیک برای پلتفرم‌های انتخاب شده
      final deviceSpecificAddressListName = addressListName ?? 'Blocked-Social-${deviceIp.replaceAll('.', '-')}';
      int addressListCount = 0;
      if (enableAddressList) {
        try {
          addressListCount = await _createAddressListForPlatforms(platforms, deviceSpecificAddressListName);
          results['address_list_entries'] = addressListCount;
          results['address_list_name'] = deviceSpecificAddressListName;
        } catch (e) {
          errors.add({
            'type': 'address_list',
            'error': e.toString(),
          });
        }
      }

      // 3. DNS Static Entries (redirect دامنه‌ها به 127.0.0.1)
      // توجه: DNS Static Entries global هستند و برای همه دستگاه‌ها اعمال می‌شوند
      // بنابراین فقط پلتفرم‌های مورد نیاز را اضافه می‌کنیم و حذف نمی‌کنیم
      // (حذف فقط در unblock انجام می‌شود و با بررسی اینکه آیا دستگاه دیگری استفاده می‌کند)
      int dnsStaticCount = 0;
      if (enableDNSStatic) {
        try {
          final socialMediaData = await _getSocialMediaAddresses();
          // فقط پلتفرم‌های انتخاب شده را اضافه می‌کنیم (بدون حذف)
          dnsStaticCount = await _addDNSStaticEntries(platforms, socialMediaData);
          results['dns_static_entries'] = dnsStaticCount;
        } catch (e) {
          errors.add({
            'type': 'dns_static',
            'error': e.toString(),
          });
        }
      }

      // 4. ایجاد Firewall Rule برای device-specific blocking
      int firewallRuleCount = 0;
      if (enableFirewallRule && enableAddressList) {
        try {
          firewallRuleCount = await _createFirewallRuleForDevice(
            deviceIp,
            deviceMac,
            deviceSpecificAddressListName,
            platforms,
            deviceName,
          );
          results['firewall_rules'] = firewallRuleCount;
        } catch (e) {
          errors.add({
            'type': 'firewall_rule',
            'error': e.toString(),
          });
        }
      }

      // 5. بلاک کردن DNS خارجی (device-specific)
      int blockedDNS = 0;
      if (blockExternalDNS) {
        try {
          blockedDNS = await _blockExternalDNSServers(deviceIp);
          results['blocked_external_dns'] = blockedDNS;
        } catch (e) {
          errors.add({
            'type': 'block_external_dns',
            'error': e.toString(),
          });
        }
      }

      // 6. بلاک کردن DoH/DoT (device-specific)
      int blockedDoHDoT = 0;
      if (blockDoHDoT) {
        try {
          blockedDoHDoT = await _blockDoHDoT(deviceIp);
          results['blocked_doh_dot'] = blockedDoHDoT;
        } catch (e) {
          errors.add({
            'type': 'block_doh_dot',
            'error': e.toString(),
          });
        }
      }

      // 7. بلاک کردن VPN protocols (device-specific)
      int blockedVPN = 0;
      if (blockVPN) {
        try {
          blockedVPN = await _blockVPNProtocols(deviceIp);
          results['blocked_vpn'] = blockedVPN;
        } catch (e) {
          errors.add({
            'type': 'block_vpn',
            'error': e.toString(),
          });
        }
      }

      return {
        'status': 'success',
        'message': 'مسدود کردن ${platforms.length} پلتفرم برای دستگاه ${deviceIp} انجام شد (Multi-layer filtering)',
        'blocked_platforms': platforms,
        'device_ip': deviceIp,
        'address_list_name': deviceSpecificAddressListName,
        'address_list_entries': addressListCount,
        'dns_static_entries': dnsStaticCount,
        'firewall_rules': firewallRuleCount,
        'blocked_external_dns': blockedDNS,
        'blocked_doh_dot': blockedDoHDoT,
        'blocked_vpn': blockedVPN,
        'dns_redirect_rules': dnsRedirectRules,
        'method': 'Multi-layer (DNS Static + Address List + Firewall + Block DNS Bypass)',
        'layer_results': results,
        'errors': errors,
        'note': 'فیلترینگ چندلایه شامل: DNS Static (بدون DNS Redirect NAT برای جلوگیری از تداخل), Address List, Firewall Rules, Block External DNS, Block DoH/DoT, Block VPN',
      };
    } catch (e) {
      throw Exception('خطا در مسدود کردن شبکه‌های اجتماعی: $e');
    }
  }

  /// رفع مسدودیت شبکه‌های اجتماعی برای یک دستگاه
  /// همه فیلترهای مربوط به این دستگاه حذف می‌شوند (device-specific): Firewall Rules, Address List, DNS Static, Block DNS/VPN rules
  Future<Map<String, dynamic>> unblockSocialMediaWithAddressList({
    required String deviceIp,
    String? deviceMac,
    String? addressListName, // اگر null باشد، از نام device-specific استفاده می‌شود
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final errors = <Map<String, dynamic>>[];
      final deviceSpecificAddressListName = addressListName ?? 'Blocked-Social-${deviceIp.replaceAll('.', '-')}';
      
      int removedRules = 0;
      int removedAddressList = 0;
      int removedDNSStatic = 0;
      int removedBlockDNS = 0;
      int removedBlockDoHDoT = 0;
      int removedBlockVPN = 0;
      int removedNATRules = 0;

      // 1. حذف Firewall Rules مربوط به این دستگاه
      try {
        final allRules = await _client!.talk(['/ip/firewall/filter/print']);
        for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        
        bool shouldRemove = false;
          
          // Firewall rule برای social media blocking
          if (srcAddress == deviceIp && 
              dstAddressList == deviceSpecificAddressListName &&
              comment.contains('Block social')) {
            shouldRemove = true;
          }
          
          // Block External DNS rules
          if (srcAddress == deviceIp && 
              comment.contains('Block External DNS') &&
              comment.contains('Device: $deviceIp')) {
            shouldRemove = true;
          }
          
          // Block DoH/DoT rules
          if (srcAddress == deviceIp && 
              (comment.contains('Block DoT') || comment.contains('Block DoH')) &&
              comment.contains('Device: $deviceIp')) {
            shouldRemove = true;
          }
          
          // Block VPN rules
          if (srcAddress == deviceIp && 
              comment.contains('Block VPN') &&
              comment.contains('Device: $deviceIp')) {
            shouldRemove = true;
          }
          
          if (shouldRemove) {
            try {
              final ruleId = rule['.id']?.toString();
              if (ruleId != null) {
                await _client!.talk(['/ip/firewall/filter/remove', '=.id=$ruleId']);
                removedRules++;
                if (comment.contains('External DNS')) removedBlockDNS++;
                if (comment.contains('DoT') || comment.contains('DoH')) removedBlockDoHDoT++;
                if (comment.contains('VPN')) removedBlockVPN++;
              }
            } catch (e) {
              // continue
            }
          }
        }
      } catch (e) {
        errors.add({
          'type': 'firewall_rules_remove',
          'error': e.toString(),
        });
      }

      // 2. حذف Address List مربوط به این دستگاه
      try {
        final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
        for (final entry in allAddressList) {
          final list = entry['list']?.toString() ?? '';
          if (list == deviceSpecificAddressListName) {
            try {
              final entryId = entry['.id']?.toString();
              if (entryId != null) {
                await _client!.talk(['/ip/firewall/address-list/remove', '=.id=$entryId']);
                removedAddressList++;
              }
            } catch (e) {
              // continue
            }
          }
        }
      } catch (e) {
        errors.add({
          'type': 'address_list_remove',
          'error': e.toString(),
        });
      }

      // 2.5. حذف DNS Redirect NAT rules (اگر وجود دارند و برای همه دستگاه‌ها هستند)
      // توجه: DNS Redirect rules ممکن است برای همه دستگاه‌ها ایجاد شده باشند
      // اگر فقط برای این دستگاه بودند، باید حذف شوند
      // اما چون ما دیگر DNS Redirect ایجاد نمی‌کنیم، این بخش فقط برای پاکسازی است
      try {
        final allNATRules = await _client!.talk(['/ip/firewall/nat/print']);
        for (final rule in allNATRules) {
          final comment = rule['comment']?.toString() ?? '';
          final chain = rule['chain']?.toString() ?? '';
          final dstPort = rule['dst-port']?.toString() ?? '';
          final srcAddress = rule['src-address']?.toString() ?? '';
          
          // اگر rule مربوط به DNS Redirect است و برای این دستگاه است
          if (chain == 'dstnat' && 
              dstPort == '53' && 
              comment.contains('DNS Redirect')) {
            // اگر rule device-specific است و برای این دستگاه است، حذف کن
            if (srcAddress == deviceIp || (srcAddress.isEmpty && comment.contains('Device: $deviceIp'))) {
              try {
                final ruleId = rule['.id']?.toString();
                if (ruleId != null) {
                  await _client!.talk(['/ip/firewall/nat/remove', '=.id=$ruleId']);
                  removedNATRules++;
                }
              } catch (e) {
                // continue
              }
            }
          }
        }
      } catch (e) {
        // ignore - اگر خطا رخ داد، ادامه بده
      }

      // 3. حذف DNS Static Entries (فقط اگر هیچ دستگاه دیگری از آن استفاده نکند)
      // توجه: DNS Static entries global هستند، پس باید بررسی کنیم که آیا دستگاه دیگری از آن استفاده می‌کند
      try {
        // پیدا کردن پلتفرم‌هایی که این دستگاه فیلتر کرده بود
        final allRules = await _client!.talk(['/ip/firewall/filter/print']);
        final platformsForThisDevice = <String>{};
        
        for (final rule in allRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final dstAddressList = rule['dst-address-list']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          
          if (srcAddress == deviceIp && 
              dstAddressList == deviceSpecificAddressListName &&
              comment.contains('Block social')) {
            final platformsMatch = RegExp(r'Platforms: (.+)').firstMatch(comment);
            if (platformsMatch != null) {
              final platforms = platformsMatch.group(1)?.split(', ') ?? [];
              platformsForThisDevice.addAll(platforms.map((p) => p.trim().toLowerCase()));
            }
          }
        }
        
        // اگر این دستگاه پلتفرمی را فیلتر کرده بود، بررسی کن که آیا دستگاه دیگری هم از آن استفاده می‌کند
        if (platformsForThisDevice.isNotEmpty) {
          final allFilters = await _client!.talk(['/ip/firewall/filter/print']);
          
          // پیدا کردن تمام دستگاه‌هایی که از پلتفرم‌های مشترک استفاده می‌کنند
          final platformsStillUsed = <String>{};
          
          for (final filter in allFilters) {
            final srcAddr = filter['src-address']?.toString() ?? '';
            final comment = filter['comment']?.toString() ?? '';
            
            // اگر دستگاه دیگری باشد (نه این دستگاه) و از social media blocking استفاده کند
            if (srcAddr != deviceIp && comment.contains('Block social')) {
              final platformsMatch = RegExp(r'Platforms: (.+)').firstMatch(comment);
              if (platformsMatch != null) {
                final platforms = platformsMatch.group(1)?.split(', ') ?? [];
                for (final platform in platforms) {
                  final platformLower = platform.trim().toLowerCase();
                  if (platformsForThisDevice.contains(platformLower)) {
                    platformsStillUsed.add(platformLower);
                  }
                }
              }
            }
          }
          
          // فقط پلتفرم‌هایی را حذف کن که دیگر هیچ دستگاهی از آن استفاده نمی‌کند
          final platformsToRemove = platformsForThisDevice.difference(platformsStillUsed);
          
          if (platformsToRemove.isNotEmpty) {
            final socialMediaData = await _getSocialMediaAddresses();
            final allDNSStatic = await _client!.talk(['/ip/dns/static/print']);
            
            for (final platform in platformsToRemove) {
              if (!socialMediaData.containsKey(platform)) continue;
              
              final domains = socialMediaData[platform]!;
              for (final domain in domains) {
                // فقط دامنه‌ها (نه IP ranges)
                if (!domain.contains('/') && !RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(domain)) {
                  for (final entry in allDNSStatic) {
                    final name = entry['name']?.toString().toLowerCase() ?? '';
                    final address = entry['address']?.toString() ?? '';
                    final comment = entry['comment']?.toString().toLowerCase() ?? '';
                    
                    if (name == domain.toLowerCase() && 
                        address == '127.0.0.1' && 
                        comment.contains('block') &&
                        comment.contains(platform)) {
                      try {
                        final entryId = entry['.id']?.toString();
                        if (entryId != null) {
                          await _client!.talk(['/ip/dns/static/remove', '=.id=$entryId']);
                          removedDNSStatic++;
                        }
                      } catch (e) {
                        // continue
                      }
                    }
                  }
                }
              }
            }
            
            // پاک کردن DNS cache
            if (removedDNSStatic > 0) {
              try {
                await _client!.talk(['/ip/dns/cache/flush']);
              } catch (e) {
                // ignore
              }
            }
          }
        }
      } catch (e) {
        errors.add({
          'type': 'dns_static_remove',
          'error': e.toString(),
        });
      }

      final totalRemoved = removedRules + removedAddressList + removedDNSStatic + removedNATRules;

      return {
        'status': 'success',
        'message': 'فیلترهای دستگاه $deviceIp حذف شدند',
        'device_ip': deviceIp,
        'removed_firewall_rules': removedRules,
        'removed_address_list_entries': removedAddressList,
        'removed_dns_static_entries': removedDNSStatic,
        'removed_nat_rules': removedNATRules,
        'removed_block_external_dns': removedBlockDNS,
        'removed_block_doh_dot': removedBlockDoHDoT,
        'removed_block_vpn': removedBlockVPN,
        'total_removed': totalRemoved,
        'method': 'Multi-layer removal (Firewall + Address List + DNS Static + NAT)',
        'note': 'همه فیلترهای مربوط به این دستگاه حذف شدند',
        'errors': errors,
      };
    } catch (e) {
      throw Exception('خطا در رفع مسدودیت: $e');
    }
  }

  /// رفع فیلتر پلتفرم‌های خاص برای یک دستگاه (برای رفع فیلتر تکی)
  /// فقط پلتفرم‌های مشخص شده رفع فیلتر می‌شوند، بقیه باقی می‌مانند
  Future<Map<String, dynamic>> unblockPlatformsForDevice({
    required String deviceIp,
    required List<String> platforms,
    String? deviceMac,
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      int removedDNSStatic = 0;

      // حذف DNS Static Entries برای پلتفرم‌های مشخص شده
      // اما فقط اگر هیچ دستگاه دیگری از آن استفاده نکند
      try {
        final socialMediaData = await _getSocialMediaAddresses();
        final allDNSStatic = await _client!.talk(['/ip/dns/static/print']);
        final allFilters = await _client!.talk(['/ip/firewall/filter/print']);
        
        // پیدا کردن تمام دستگاه‌هایی که از این پلتفرم‌ها استفاده می‌کنند
        final platformsStillUsed = <String>{};
        
        for (final filter in allFilters) {
          final srcAddr = filter['src-address']?.toString() ?? '';
          final comment = filter['comment']?.toString() ?? '';
          
          // اگر دستگاه دیگری باشد (نه این دستگاه) و از social media blocking استفاده کند
          if (srcAddr != deviceIp && comment.contains('Block social')) {
            final platformsMatch = RegExp(r'Platforms: (.+)').firstMatch(comment);
            if (platformsMatch != null) {
              final platformList = platformsMatch.group(1)?.split(', ') ?? [];
              for (final platform in platformList) {
                final platformLower = platform.trim().toLowerCase();
                if (platforms.contains(platformLower)) {
                  platformsStillUsed.add(platformLower);
                }
              }
            }
          }
        }
        
        // فقط پلتفرم‌هایی را حذف کن که دیگر هیچ دستگاهی از آن استفاده نمی‌کند
        final platformsToRemove = platforms.where((p) => !platformsStillUsed.contains(p.toLowerCase())).toList();
        
        for (final platform in platformsToRemove) {
          if (!socialMediaData.containsKey(platform.toLowerCase())) continue;
          
          final domains = socialMediaData[platform.toLowerCase()]!;
          for (final domain in domains) {
            // فقط دامنه‌ها (نه IP ranges)
            if (!domain.contains('/') && !RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(domain)) {
              for (final entry in allDNSStatic) {
                final name = entry['name']?.toString().toLowerCase() ?? '';
                final address = entry['address']?.toString() ?? '';
                final comment = entry['comment']?.toString().toLowerCase() ?? '';
                
                if (name == domain.toLowerCase() && 
                    address == '127.0.0.1' && 
                    comment.contains('block') &&
                    comment.contains(platform.toLowerCase())) {
                  try {
                    final entryId = entry['.id']?.toString();
                    if (entryId != null) {
                      await _client!.talk(['/ip/dns/static/remove', '=.id=$entryId']);
                      removedDNSStatic++;
                    }
                  } catch (e) {
                    // continue
                  }
                }
              }
            }
          }
        }
        
        // پاک کردن DNS cache
        if (removedDNSStatic > 0) {
          try {
            await _client!.talk(['/ip/dns/cache/flush']);
          } catch (e) {
            // ignore
          }
        }
      } catch (e) {
        // ignore
      }

      return {
        'status': 'success',
        'message': 'رفع فیلتر ${platforms.length} پلتفرم برای دستگاه $deviceIp',
        'device_ip': deviceIp,
        'unblocked_platforms': platforms,
        'removed_dns_static_entries': removedDNSStatic,
        'note': 'DNS Static entries فقط در صورتی حذف شدند که هیچ دستگاه دیگری از آن استفاده نکند',
      };
    } catch (e) {
      throw Exception('خطا در رفع فیلتر پلتفرم‌ها: $e');
    }
  }

  /// بررسی وضعیت فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  /// بررسی می‌کند: Firewall Rules, Address List, DNS Static Entries
  Future<Map<String, dynamic>> checkSocialMediaBlockStatus({
    required String deviceIp,
    String? deviceMac,
    String? addressListName,
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      final deviceSpecificAddressListName = addressListName ?? 'Blocked-Social-${deviceIp.replaceAll('.', '-')}';
      final blockedPlatforms = <String>[];
      bool isBlocked = false;

      // 1. بررسی Firewall Rules
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      final matchingRules = <Map<String, dynamic>>[];

      for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final srcMac = rule['src-mac-address']?.toString() ?? '';
        final disabled = rule['disabled']?.toString().toLowerCase() == 'true';

        bool matches = srcAddress == deviceIp && dstAddressList == deviceSpecificAddressListName;
        
        if (deviceMac != null && deviceMac.isNotEmpty) {
          matches = matches && (srcMac.isEmpty || srcMac.toUpperCase() == deviceMac.toUpperCase());
        }

        if (matches && comment.contains('Block social')) {
          isBlocked = true;
          final platformsMatch = RegExp(r'Platforms: (.+)').firstMatch(comment);
          final platforms = platformsMatch?.group(1)?.split(', ') ?? [];
          blockedPlatforms.addAll(platforms.map((p) => p.trim().toLowerCase()));
          
          matchingRules.add({
            'rule_id': rule['.id'],
            'comment': comment,
            'disabled': disabled,
            'chain': rule['chain'],
            'action': rule['action'],
            'src_address': srcAddress,
            'dst_address_list': dstAddressList,
            'platforms': platforms,
          });
        }
      }

      // 2. بررسی Address List
      int addressListCount = 0;
      try {
        final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
        for (final entry in allAddressList) {
          final list = entry['list']?.toString() ?? '';
          if (list == deviceSpecificAddressListName) {
            addressListCount++;
          }
        }
      } catch (e) {
        // ignore
      }

      // 3. بررسی DNS Static Entries
      final blockedDomains = <String>[];
      final socialMediaData = await _getSocialMediaAddresses();
      final allSocialMediaDomains = <String>{};
      
      for (final domains in socialMediaData.values) {
        for (final domain in domains) {
          if (!domain.contains('/') && !RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(domain)) {
            allSocialMediaDomains.add(domain.toLowerCase());
          }
        }
      }
      
      try {
        final allDNSStatic = await _client!.talk(['/ip/dns/static/print']);
        for (final entry in allDNSStatic) {
          final address = entry['address']?.toString() ?? '';
          final name = entry['name']?.toString().toLowerCase() ?? '';
          final comment = entry['comment']?.toString().toLowerCase() ?? '';
          
          if (address == '127.0.0.1' && comment.contains('block')) {
            if (allSocialMediaDomains.contains(name)) {
              blockedDomains.add(name);
              isBlocked = true;
              
              // استخراج platform از comment
              for (final platform in socialMediaData.keys) {
                final domains = socialMediaData[platform]!;
                if (domains.any((d) => d.toLowerCase() == name)) {
                  if (!blockedPlatforms.contains(platform.toLowerCase())) {
                    blockedPlatforms.add(platform.toLowerCase());
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        // ignore
      }

      final activeRules = matchingRules.where((r) => r['disabled'] == false).length;
      final allRulesActive = isBlocked && matchingRules.isNotEmpty && activeRules == matchingRules.length;

      return {
        'status': 'success',
        'is_blocked': isBlocked,
        'blocked_platforms': blockedPlatforms.toSet().toList(),
        'blocked_domains': blockedDomains,
        'device_ip': deviceIp,
        'address_list_name': deviceSpecificAddressListName,
        'address_list_count': addressListCount,
        'total_rules': matchingRules.length,
        'active_rules': activeRules,
        'all_rules_active': allRulesActive,
        'rules': matchingRules,
        'dns_static_count': blockedDomains.length,
        'method': 'Multi-layer (Firewall + Address List + DNS Static)',
      };
    } catch (e) {
      throw Exception('خطا در بررسی وضعیت فیلترینگ: $e');
    }
  }

  /// بررسی اینکه آیا یک رشته IP معتبر است
  bool _isValidIP(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    try {
      for (final part in parts) {
        final num = int.parse(part);
        if (num < 0 || num > 255) return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// فعال‌سازی DNS سرور روتر
  Future<void> _enableDNSServer() async {
    try {
      // بررسی وضعیت DNS
      final dnsSettings = await _client!.talk(['/ip/dns/print']);
      if (dnsSettings.isEmpty) return;

      // فعال کردن allow-remote-requests
      await _client!.talk([
        '/ip/dns/set',
        '=.id=${dnsSettings[0]['.id']}',
        '=allow-remote-requests=yes',
      ]);
    } catch (e) {
      // ignore - ممکن است از قبل فعال باشد
    }
  }

  // متد _setupDNSRedirect حذف شد
  // DNS Redirect NAT rules برای همه دستگاه‌ها اعمال می‌شوند و باعث تداخل می‌شوند
  // به جای آن، فقط از DNS Static Entries استفاده می‌کنیم که با Address List + Firewall Rules ترکیب می‌شوند

  /// بلاک کردن DNS سرورهای خارجی
  Future<int> _blockExternalDNSServers(String? deviceIp) async {
    final publicDNSServers = [
      '8.8.8.8',      // Google DNS
      '8.8.4.4',      // Google DNS
      '1.1.1.1',      // Cloudflare DNS
      '1.0.0.1',      // Cloudflare DNS
      '9.9.9.9',      // Quad9
      '208.67.222.222', // OpenDNS
      '208.67.220.220', // OpenDNS
    ];

    int blockedCount = 0;
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);

    for (final dns in publicDNSServers) {
      try {
        // بررسی وجود rule
        bool ruleExists = false;
        for (final rule in allRules) {
          final dstAddress = rule['dst-address']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final srcAddress = rule['src-address']?.toString() ?? '';
          
          if (dstAddress == dns && 
              comment.contains('Block External DNS') &&
              (deviceIp == null || srcAddress == deviceIp || srcAddress.isEmpty)) {
            ruleExists = true;
            break;
          }
        }

          if (!ruleExists) {
          final ruleParams = <String, String>{
            'chain': 'forward',
            'protocol': 'udp',
            'dst-port': '53',
            'dst-address': dns,
            'action': 'drop',
            'comment': 'Block External DNS - $dns',
          };

          // اگر deviceIp null باشد، rule global است (برای همه)
          // اگر deviceIp مشخص باشد، فقط برای آن دستگاه اعمال می‌شود
          if (deviceIp != null && deviceIp.isNotEmpty) {
            ruleParams['src-address'] = deviceIp;
            ruleParams['comment'] = 'Block External DNS - $dns - Device: $deviceIp';
          }

          final addCommand = <String>['/ip/firewall/filter/add'];
          ruleParams.forEach((key, value) {
            addCommand.add('=$key=$value');
          });

          await _client!.talk(addCommand);
          blockedCount++;
        }
      } catch (e) {
        // continue with next DNS server
      }
    }

    return blockedCount;
  }

  /// بلاک کردن DNS bypass (DoH/DoT و DNS خارجی)
  Future<int> _blockDNSBypass(String? deviceIp) async {
    int totalBlocked = 0;
    
    // 1. بلاک کردن DoH/DoT
    try {
      final dohDotCount = await _blockDoHDoT(deviceIp);
      totalBlocked += dohDotCount;
    } catch (e) {
      // continue
    }
    
    // 2. بلاک کردن DNS سرورهای عمومی خارجی
    final publicDNSServers = [
      '8.8.8.8',      // Google DNS
      '8.8.4.4',      // Google DNS
      '1.1.1.1',      // Cloudflare DNS
      '1.0.0.1',      // Cloudflare DNS
      '9.9.9.9',      // Quad9
      '208.67.222.222', // OpenDNS
      '208.67.220.220', // OpenDNS
    ];
    
    try {
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      
      for (final dnsServer in publicDNSServers) {
        bool ruleExists = false;
        
        for (final rule in allRules) {
          final dstAddress = rule['dst-address']?.toString() ?? '';
          final dstPort = rule['dst-port']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final srcAddress = rule['src-address']?.toString() ?? '';
          
          if (dstAddress == dnsServer && 
              (dstPort == '53' || dstPort == '853') &&
              comment.contains('Block DNS') &&
              (deviceIp == null || srcAddress == deviceIp || srcAddress.isEmpty)) {
            ruleExists = true;
            break;
          }
        }
        
        if (!ruleExists) {
          try {
            // بلاک UDP DNS
            final udpParams = <String, String>{
              'chain': 'forward',
              'protocol': 'udp',
              'dst-address': dnsServer,
              'dst-port': '53',
              'action': 'drop',
              'comment': deviceIp != null && deviceIp.isNotEmpty
                  ? 'Block DNS - $dnsServer - Device: $deviceIp'
                  : 'Block DNS - $dnsServer',
            };
            
            if (deviceIp != null && deviceIp.isNotEmpty) {
              udpParams['src-address'] = deviceIp;
            }
            
            final udpCommand = <String>['/ip/firewall/filter/add'];
            udpParams.forEach((key, value) {
              udpCommand.add('=$key=$value');
            });
            
            await _client!.talk(udpCommand);
            totalBlocked++;
            
            // بلاک TCP DNS
            final tcpParams = <String, String>{
              'chain': 'forward',
              'protocol': 'tcp',
              'dst-address': dnsServer,
              'dst-port': '53',
              'action': 'drop',
              'comment': deviceIp != null && deviceIp.isNotEmpty
                  ? 'Block DNS - $dnsServer - Device: $deviceIp'
                  : 'Block DNS - $dnsServer',
            };
            
            if (deviceIp != null && deviceIp.isNotEmpty) {
              tcpParams['src-address'] = deviceIp;
            }
            
            final tcpCommand = <String>['/ip/firewall/filter/add'];
            tcpParams.forEach((key, value) {
              tcpCommand.add('=$key=$value');
            });
            
            await _client!.talk(tcpCommand);
            totalBlocked++;
          } catch (e) {
            // continue with next DNS server
          }
        }
      }
    } catch (e) {
      // continue
    }
    
    return totalBlocked;
  }

  /// بلاک کردن DoH (DNS over HTTPS) و DoT (DNS over TLS)
  Future<int> _blockDoHDoT(String? deviceIp) async {
    int blockedCount = 0;

    // 1. بلاک کردن DoT (پورت 853)
    try {
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      bool dotRuleExists = false;

      for (final rule in allRules) {
        final dstPort = rule['dst-port']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final srcAddress = rule['src-address']?.toString() ?? '';
        
        if (dstPort == '853' && 
            comment.contains('Block DoT') &&
            (deviceIp == null || srcAddress == deviceIp || srcAddress.isEmpty)) {
          dotRuleExists = true;
          break;
        }
      }

          if (!dotRuleExists) {
        final ruleParams = <String, String>{
          'chain': 'forward',
          'protocol': 'tcp',
          'dst-port': '853',
          'action': 'drop',
          'comment': deviceIp != null && deviceIp.isNotEmpty
              ? 'Block DoT (DNS over TLS) - Device: $deviceIp'
              : 'Block DoT (DNS over TLS)',
        };

        if (deviceIp != null && deviceIp.isNotEmpty) {
          ruleParams['src-address'] = deviceIp;
        }

        final addCommand = <String>['/ip/firewall/filter/add'];
        ruleParams.forEach((key, value) {
          addCommand.add('=$key=$value');
        });

        await _client!.talk(addCommand);
        blockedCount++;
      }
    } catch (e) {
      // continue
    }

    // 2. بلاک کردن DoH (DNS over HTTPS) - host های شناخته شده
    final dohHosts = [
      'dns.google',           // Google DoH
      'cloudflare-dns.com',   // Cloudflare DoH
      'dns.quad9.net',        // Quad9 DoH
      'dns.opendns.com',      // OpenDNS DoH
    ];

    // برای DoH، از TLS Host Filtering استفاده می‌کنیم (RouterOS v6.41+)
    try {
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      
      for (final host in dohHosts) {
        bool dohRuleExists = false;
        
        for (final rule in allRules) {
          final tlsHost = rule['tls-host']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final srcAddress = rule['src-address']?.toString() ?? '';
          
          if (tlsHost == host && 
              comment.contains('Block DoH') &&
              (deviceIp == null || srcAddress == deviceIp || srcAddress.isEmpty)) {
            dohRuleExists = true;
            break;
          }
        }

        if (!dohRuleExists) {
          try {
            final ruleParams = <String, String>{
              'chain': 'forward',
              'protocol': 'tcp',
              'dst-port': '443',
              'tls-host': host,
              'action': 'drop',
              'comment': deviceIp != null && deviceIp.isNotEmpty
                  ? 'Block DoH (DNS over HTTPS) - $host - Device: $deviceIp'
                  : 'Block DoH (DNS over HTTPS) - $host',
            };

            if (deviceIp != null && deviceIp.isNotEmpty) {
              ruleParams['src-address'] = deviceIp;
            }

            final addCommand = <String>['/ip/firewall/filter/add'];
            ruleParams.forEach((key, value) {
              addCommand.add('=$key=$value');
            });

            await _client!.talk(addCommand);
            blockedCount++;
          } catch (e) {
            // TLS host filtering ممکن است در RouterOS قدیمی کار نکند
          }
        }
      }
    } catch (e) {
      // continue
    }

    return blockedCount;
  }

  /// بلاک کردن پروتکل‌های VPN
  Future<int> _blockVPNProtocols(String? deviceIp) async {
    final vpnPorts = [
      {'protocol': 'udp', 'port': '1194', 'name': 'OpenVPN'},
      {'protocol': 'udp', 'port': '500', 'name': 'IPSec'},
      {'protocol': 'udp', 'port': '4500', 'name': 'IPSec NAT-T'},
      {'protocol': 'udp', 'port': '51820', 'name': 'WireGuard'},
      {'protocol': 'tcp', 'port': '1723', 'name': 'PPTP'},
      {'protocol': 'tcp', 'port': '443', 'name': 'OpenVPN TCP'},
    ];

    int blockedCount = 0;
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);

    for (final vpn in vpnPorts) {
      try {
        bool ruleExists = false;
        
        for (final rule in allRules) {
          final protocol = rule['protocol']?.toString() ?? '';
          final dstPort = rule['dst-port']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final srcAddress = rule['src-address']?.toString() ?? '';
          
          if (protocol == vpn['protocol'] &&
              dstPort == vpn['port'] &&
              comment.contains('Block VPN') &&
              (deviceIp == null || srcAddress == deviceIp || srcAddress.isEmpty)) {
            ruleExists = true;
            break;
          }
        }

        if (!ruleExists) {
          final ruleParams = <String, String>{
            'chain': 'forward',
            'protocol': vpn['protocol']!,
            'dst-port': vpn['port']!,
            'action': 'drop',
            'comment': deviceIp != null && deviceIp.isNotEmpty
                ? 'Block VPN - ${vpn['name']} - Device: $deviceIp'
                : 'Block VPN - ${vpn['name']}',
          };

          if (deviceIp != null && deviceIp.isNotEmpty) {
            ruleParams['src-address'] = deviceIp;
          }

          final addCommand = <String>['/ip/firewall/filter/add'];
          ruleParams.forEach((key, value) {
            addCommand.add('=$key=$value');
          });

          await _client!.talk(addCommand);
          blockedCount++;
        }
      } catch (e) {
        // continue with next VPN
      }
    }

    return blockedCount;
  }

  /// ایجاد Address List برای پلتفرم‌های انتخاب شده
  /// این متد IPهای مربوط به دامنه‌ها را resolve می‌کند و به Address List اضافه می‌کند
  /// ابتدا همه entries قبلی این Address List را حذف می‌کند، سپس فقط پلتفرم‌های انتخاب شده را اضافه می‌کند
  Future<int> _createAddressListForPlatforms(
    List<String> platforms,
    String addressListName,
  ) async {
    // ابتدا همه entries قبلی این Address List را حذف می‌کنیم
    try {
      final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
      for (final entry in allAddressList) {
        final list = entry['list']?.toString() ?? '';
        if (list == addressListName) {
          try {
            final entryId = entry['.id']?.toString();
            if (entryId != null) {
              await _client!.talk(['/ip/firewall/address-list/remove', '=.id=$entryId']);
            }
          } catch (e) {
            // continue
          }
        }
      }
    } catch (e) {
      // ignore - اگر خطا رخ داد، ادامه بده
    }

    // حالا فقط پلتفرم‌های انتخاب شده را اضافه می‌کنیم
    int addedCount = 0;
    final socialMediaData = await _getSocialMediaAddresses();
    final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
    
    // مجموعه‌ای از IPهایی که قبلاً اضافه شده‌اند (برای جلوگیری از duplicate)
    final existingAddresses = <String>{};
    for (final entry in allAddressList) {
      final list = entry['list']?.toString() ?? '';
      final address = entry['address']?.toString() ?? '';
      if (list == addressListName) {
        existingAddresses.add(address);
      }
    }

    for (final platform in platforms) {
      final platformLower = platform.toLowerCase();
      if (!socialMediaData.containsKey(platformLower)) continue;

      final addresses = socialMediaData[platformLower]!;
      
      for (final address in addresses) {
        try {
          // اگر IP range یا IP مستقیم است، مستقیم اضافه کن
          if (address.contains('/') || RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(address)) {
            if (!existingAddresses.contains(address)) {
              await _client!.talk([
                '/ip/firewall/address-list/add',
                '=list=$addressListName',
                '=address=$address',
                '=comment=Block $platformLower',
              ]);
              existingAddresses.add(address);
              addedCount++;
            }
          } else {
            // اگر دامنه است، سعی کن resolve کنی
            // در RouterOS می‌توان از resolve استفاده کرد
            bool resolved = false;
            try {
              final resolveResult = await _client!.talk([
                '/resolve',
                '=type=A',
                '=host=$address',
              ]);
              
              if (resolveResult.isNotEmpty) {
                final ip = resolveResult[0]['data']?.toString() ?? '';
                if (_isValidIP(ip) && !existingAddresses.contains(ip)) {
                  await _client!.talk([
                    '/ip/firewall/address-list/add',
                    '=list=$addressListName',
                    '=address=$ip',
                    '=comment=Block $platformLower - $address',
                  ]);
                  existingAddresses.add(ip);
                  addedCount++;
                  resolved = true;
                }
              }
            } catch (e) {
              // ignore resolve errors
            }
            
            // اگر resolve نشد، دامنه را هم اضافه کن (RouterOS می‌تواند در runtime resolve کند)
            // برای اینستاگرام و فیسبوک که از CDN استفاده می‌کنند، دامنه‌ها را هم اضافه می‌کنیم
            if (!resolved && !existingAddresses.contains(address)) {
              try {
                // برای اینستاگرام و فیسبوک، همه دامنه‌ها را اضافه می‌کنیم (حتی subdomain)
                // چون از CDN استفاده می‌کنند و IPها تغییر می‌کنند
                if (platformLower == 'instagram' || platformLower == 'facebook') {
                  await _client!.talk([
                    '/ip/firewall/address-list/add',
                    '=list=$addressListName',
                    '=address=$address',
                    '=comment=Block $platformLower - domain',
                  ]);
                  existingAddresses.add(address);
                  addedCount++;
                } else {
                  // برای سایر پلتفرم‌ها، فقط دامنه‌های اصلی
                  if (!address.contains('.') || address.split('.').length <= 3) {
                    await _client!.talk([
                      '/ip/firewall/address-list/add',
                      '=list=$addressListName',
                      '=address=$address',
                      '=comment=Block $platformLower - domain',
                    ]);
                    existingAddresses.add(address);
                    addedCount++;
                  }
                }
              } catch (e) {
                // continue
              }
            }
          }
        } catch (e) {
          // continue with next address
        }
      }
    }

    return addedCount;
  }

  /// ایجاد TLS-SNI Firewall Rules برای پلتفرم‌های انتخاب شده (با wildcard)
  /// این متد از wildcard استفاده می‌کند (مثل *.facebook.com) برای پوشش کامل
  Future<int> _createTLSHostRulesForPlatforms(
    String deviceIp,
    String? deviceMac,
    List<String> platforms,
    String? deviceName,
  ) async {
    int rulesAdded = 0;
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);
    
    // لیست دامنه‌های مهم برای هر پلتفرم (با wildcard برای پوشش کامل)
    final platformDomains = {
      'facebook': [
        '*.facebook.com',
        'facebook.com',
        'www.facebook.com',
        'm.facebook.com',
        'mobile.facebook.com',
        'touch.facebook.com',
        'fb.com',
        '*.fb.com',
        'www.fb.com',
        '*.fbcdn.net',
        'fbcdn.net',
        '*.fbsbx.com',
        'fbsbx.com',
        'connect.facebook.net',
        'graph.facebook.com',
        'graph-api.facebook.com',
        'apps.facebook.com',
        'upload.facebook.com',
        'web.facebook.com',
        'web-fallback.facebook.com',
        'edge-chat.facebook.com',
        'api.facebook.com',
        'facebook.net',
        'fbstatic.com',
        'fbpigeon.com',
        'facebook-hardware.com',
        'messenger.com',
        '*.messenger.com',
        'www.messenger.com',
        'secure.facebook.com',
        'static.xx.fbcdn.net',
        'fbexternal-a.akamaihd.net',
        'fbexternal-b.akamaihd.net',
      ],
      'instagram': [
        '*.instagram.com',
        '*.cdninstagram.com',
        '*.fbcdn.net', // CDN مشترک
      ],
      'telegram': [
        '*.telegram.org',
        '*.t.me',
        '*.telegram.me',
      ],
      'tiktok': [
        '*.tiktok.com',
        '*.tiktokcdn.com',
        '*.tiktokv.com',
      ],
      'whatsapp': [
        '*.whatsapp.com',
        '*.whatsapp.net',
        '*.wa.me',
      ],
      'youtube': [
        '*.youtube.com',
        '*.googlevideo.com',
        '*.ytimg.com',
      ],
    };
    
    for (final platform in platforms) {
      final platformLower = platform.toLowerCase();
      if (!platformDomains.containsKey(platformLower)) continue;
      
      final domains = platformDomains[platformLower]!;
      print('[DEBUG] _createTLSHostRulesForPlatforms: Creating TLS-SNI rules for $platformLower (${domains.length} domains)');
      
      for (final domain in domains) {
        try {
          // بررسی وجود rule قبلی
          bool ruleExists = false;
          for (final rule in allRules) {
            final srcAddress = rule['src-address']?.toString() ?? '';
            final tlsHost = rule['tls-host']?.toString() ?? '';
            final comment = rule['comment']?.toString() ?? '';
            
            if (srcAddress == deviceIp &&
                tlsHost == domain &&
                (comment.contains('SM-Filter') || comment.contains('Block social'))) {
              ruleExists = true;
              break;
            }
          }
          
          if (!ruleExists) {
            // ایجاد TLS-SNI rule برای HTTPS (پورت 443)
            try {
              final ruleParams = <String, String>{
                'chain': 'forward',
                'protocol': 'tcp',
                'dst-port': '443',
                'src-address': deviceIp,
                'tls-host': domain,
                'action': 'drop',
                'comment': 'SM-Filter:Platform=$platformLower|Block $platformLower by SNI - $domain - Device: ${deviceName ?? deviceIp}',
              };
              
              if (deviceMac != null && deviceMac.isNotEmpty) {
                ruleParams['src-mac-address'] = deviceMac;
              }
              
              final addCommand = <String>['/ip/firewall/filter/add'];
              ruleParams.forEach((key, value) {
                addCommand.add('=$key=$value');
              });
              
              await _client!.talk(addCommand);
              rulesAdded++;
              print('[DEBUG] _createTLSHostRulesForPlatforms: Created TLS-SNI rule for $platformLower: $domain');
            } catch (e) {
              print('[DEBUG] _createTLSHostRulesForPlatforms: Error creating TLS-SNI rule for $domain: $e');
              // اگر TLS-SNI پشتیبانی نمی‌شود، continue می‌کنیم
            }
          } else {
            print('[DEBUG] _createTLSHostRulesForPlatforms: TLS-SNI rule already exists for $platformLower: $domain');
          }
        } catch (e) {
          print('[DEBUG] _createTLSHostRulesForPlatforms: Error processing domain $domain: $e');
          // continue with next domain
        }
      }
    }
    
    return rulesAdded;
  }

  /// ایجاد TLS-SNI Firewall Rules (روش اصلی برای فیلترینگ HTTPS)
  /// این روش از tls-host استفاده می‌کند که بهترین روش برای RouterOS v6.41+ است
  Future<int> _createTLSHostRules(
    String deviceIp,
    String? deviceMac,
    List<String> platforms,
    String? deviceName,
  ) async {
    int rulesAdded = 0;
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);
    
    // پیدا کردن اولین rule در chain forward برای قرار دادن rules جدید در اول لیست
    String? firstRuleId;
    try {
      final forwardRules = allRules.where((r) => r['chain']?.toString() == 'forward').toList();
      if (forwardRules.isNotEmpty) {
        firstRuleId = forwardRules[0]['.id']?.toString();
      }
    } catch (e) {
      // ignore
    }
    
    // لیست کامل دامنه‌های اصلی برای هر پلتفرم (برای TLS-SNI)
    // الگو: همان روشی که برای تلگرام کار کرده (بدون wildcard، فقط دامنه‌های اصلی)
    final mainDomains = {
      'youtube': [
        'youtube.com',
        'www.youtube.com',
        'youtu.be',
        'm.youtube.com',
        'googlevideo.com',
        'ytimg.com',
        'i.ytimg.com',
        'yt3.ggpht.com',
        'youtube-nocookie.com',
        'music.youtube.com',
        'youtubeeducation.com',
        'googleapis.com',
        'gstatic.com',
        'google.com',
        'ggpht.com',
        'googleusercontent.com',
        'gvt1.com',
        'gvt2.com',
        'gvt3.com',
      ],
      'instagram': [
        'instagram.com',
        'www.instagram.com',
        'm.instagram.com',
        'api.instagram.com',
        'i.instagram.com',
        'graph.instagram.com',
        'cdninstagram.com',
        'instagr.am',
        'ig.me',
        'fbcdn.net', // CDN مشترک با فیسبوک
        'instagram.net',
      ],
      'facebook': [
        'facebook.com',
        'www.facebook.com',
        'fb.com',
        'www.fb.com',
        'm.facebook.com',
        'mobile.facebook.com',
        'touch.facebook.com',
        'login.facebook.com',
        'graph.facebook.com',
        'graph-api.facebook.com',
        'fbcdn.net',
        'static.ak.fbcdn.net',
        'scontent.xx.fbcdn.net',
        'connect.facebook.net',
        'apps.facebook.com',
        'upload.facebook.com',
        'web.facebook.com',
        'web-fallback.facebook.com',
        'edge-chat.facebook.com',
        'api.facebook.com',
        'facebook.net',
        'fbstatic.com',
        'fbsbx.com',
        'fbpigeon.com',
        'facebook-hardware.com',
        'messenger.com',
        'www.messenger.com',
      ],
      'tiktok': [
        'tiktok.com',
        'www.tiktok.com',
        'tiktokcdn.com',
        'tiktokv.com',
        'tiktok.net',
        'v.tiktok.net',
        'v.tiktok.com',
        'tiktok.org',
        'musical.ly',
        'muscdn.com',
        'ibyteimg.com',
        'bytecdn.cn',
        'byted.org',
        'byteoversea.com',
      ],
      'twitter': [
        'twitter.com',
        'www.twitter.com',
        'twimg.com',
        't.co',
        'twitpic.com',
      ],
      'telegram': [
        // الگوی موفق - همان دامنه‌هایی که برای تلگرام کار کرده
        'telegram.org',
        'web.telegram.org',
        't.me',
        'telegram.me',
        'telesco.pe',
        'tg.dev',
        'core.telegram.org',
      ],
      'whatsapp': [
        'whatsapp.com',
        'web.whatsapp.com',
        'whatsapp.net',
        'wa.me',
        'wl.co',
        'whatsapp.org',
        'whatsapp.info',
        'whatsapp.tv',
        'whatsappbrand.com',
        'whatsapp-plus.me',
        'whatsapp-plus.net',
        'whatsapp-plus.info',
      ],
      'snapchat': [
        'snapchat.com',
        'www.snapchat.com',
        'snap-dev.net',
        'sc-cdn.net',
      ],
      'linkedin': [
        'linkedin.com',
        'www.linkedin.com',
        'licdn.com',
      ],
    };
    
    for (final platform in platforms) {
      final platformLower = platform.toLowerCase();
      if (!mainDomains.containsKey(platformLower)) continue;
      
      final domains = mainDomains[platformLower]!;
      
      for (final domain in domains) {
        try {
          // بررسی وجود rule قبلی
          bool ruleExists = false;
          for (final rule in allRules) {
            final srcAddress = rule['src-address']?.toString() ?? '';
            final tlsHost = rule['tls-host']?.toString() ?? '';
            final comment = rule['comment']?.toString() ?? '';
            
            if (srcAddress == deviceIp &&
                tlsHost == domain &&
                comment.contains('Block social')) {
              ruleExists = true;
              break;
            }
          }
          
          if (!ruleExists) {
            // ایجاد TLS-SNI rule برای HTTPS (پورت 443)
            try {
              final ruleParams = <String, String>{
                'chain': 'forward',
                'protocol': 'tcp',
                'dst-port': '443',
                'src-address': deviceIp,
                'tls-host': domain,
                'action': 'drop',
                'comment': 'SM-Filter:Platform=$platformLower|Block social - $platformLower - $domain - Device: ${deviceName ?? deviceIp}',
              };
              
              if (deviceMac != null && deviceMac.isNotEmpty) {
                ruleParams['src-mac-address'] = deviceMac;
              }
              
              // قرار دادن rule در اول لیست
              if (firstRuleId != null) {
                ruleParams['place-before'] = firstRuleId;
              }
              
              final addCommand = <String>['/ip/firewall/filter/add'];
              ruleParams.forEach((key, value) {
                addCommand.add('=$key=$value');
              });
              
              await _client!.talk(addCommand);
              rulesAdded++;
            } catch (e) {
              // اگر TLS-SNI پشتیبانی نمی‌شود (RouterOS قدیمی)، از rule بدون tls-host استفاده می‌کنیم
              // این rule برای HTTP (پورت 80) کار می‌کند
              try {
                final httpRuleParams = <String, String>{
                  'chain': 'forward',
                  'protocol': 'tcp',
                  'dst-port': '80',
                  'src-address': deviceIp,
                  'action': 'drop',
                  'comment': 'SM-Filter:Platform=$platformLower|Block social HTTP - $platformLower - $domain - Device: ${deviceName ?? deviceIp}',
                };
                
                if (deviceMac != null && deviceMac.isNotEmpty) {
                  httpRuleParams['src-mac-address'] = deviceMac;
                }
                
                if (firstRuleId != null) {
                  httpRuleParams['place-before'] = firstRuleId;
                }
                
                final httpCommand = <String>['/ip/firewall/filter/add'];
                httpRuleParams.forEach((key, value) {
                  httpCommand.add('=$key=$value');
                });
                
                await _client!.talk(httpCommand);
                rulesAdded++;
              } catch (e2) {
                // ignore - continue with next domain
              }
            }
          }
        } catch (e) {
          // continue with next domain
        }
      }
    }
    
    return rulesAdded;
  }

  /// Resolve کردن دامنه‌ها و اضافه کردن IPها به Address-List
  /// این متد دامنه‌های مهم را resolve می‌کند و IPهای واقعی را به Address-List اضافه می‌کند
  /// الگو: همان روشی که برای تلگرام کار کرده (IP range + resolve دامنه‌ها)
  Future<int> _resolveAndAddDomainsToAddressList(
    List<String> platforms,
    String addressListName,
    Map<String, List<String>> socialMediaData,
  ) async {
    int resolvedCount = 0;
    
    // لیست کامل دامنه‌های مهم برای resolve - مطابق با الگوی تلگرام
    final criticalDomains = <String>[];
    
    // برای هر پلتفرم، همه دامنه‌های مهم را اضافه می‌کنیم (مطابق با الگوی تلگرام)
    if (platforms.contains('instagram')) {
      criticalDomains.addAll([
        'instagram.com',
        'www.instagram.com',
        'm.instagram.com',
        'api.instagram.com',
        'i.instagram.com',
        'graph.instagram.com',
        'cdninstagram.com',
        'instagr.am',
        'ig.me',
        'fbcdn.net', // CDN مشترک با فیسبوک
        'instagram.net',
      ]);
    }
    
    if (platforms.contains('facebook')) {
      criticalDomains.addAll([
        'facebook.com',
        'www.facebook.com',
        'm.facebook.com',
        'mobile.facebook.com',
        'touch.facebook.com',
        'fb.com',
        'www.fb.com',
        'login.facebook.com',
        'graph.facebook.com',
        'graph-api.facebook.com',
        'connect.facebook.net',
        'fbcdn.net',
        'static.ak.fbcdn.net',
        'scontent.xx.fbcdn.net',
        'apps.facebook.com',
        'upload.facebook.com',
        'web.facebook.com',
        'web-fallback.facebook.com',
        'edge-chat.facebook.com',
        'api.facebook.com',
        'facebook.net',
        'fbstatic.com',
        'fbsbx.com',
        'fbpigeon.com',
        'facebook-hardware.com',
        'messenger.com',
        'www.messenger.com',
        'secure.facebook.com',
        'static.xx.fbcdn.net',
        'scontent-a.xx.fbcdn.net',
        'scontent-b.xx.fbcdn.net',
        'scontent-c.xx.fbcdn.net',
        'scontent-d.xx.fbcdn.net',
        'scontent-e.xx.fbcdn.net',
        'scontent-f.xx.fbcdn.net',
        'fbexternal-a.akamaihd.net',
        'fbexternal-b.akamaihd.net',
      ]);
    }
    
    if (platforms.contains('tiktok')) {
      criticalDomains.addAll([
        'tiktok.com',
        'www.tiktok.com',
        'tiktokcdn.com',
        'tiktokv.com',
        'tiktok.net',
        'v.tiktok.net',
        'v.tiktok.com',
        'tiktok.org',
        'musical.ly',
        'muscdn.com',
        'ibyteimg.com',
        'bytecdn.cn',
        'byted.org',
        'byteoversea.com',
      ]);
    }
    
    if (platforms.contains('whatsapp')) {
      criticalDomains.addAll([
        'whatsapp.com',
        'web.whatsapp.com',
        'whatsapp.net',
        'wa.me',
        'wl.co',
        'whatsapp.org',
        'whatsapp.info',
        'whatsapp.tv',
        'whatsappbrand.com',
      ]);
    }
    
    if (platforms.contains('telegram')) {
      // تلگرام - الگوی موفق
      criticalDomains.addAll([
        'telegram.org',
        'web.telegram.org',
        't.me',
        'telegram.me',
        'telesco.pe',
        'tg.dev',
        'core.telegram.org',
      ]);
    }
    
    if (platforms.contains('youtube')) {
      criticalDomains.addAll([
        'youtube.com',
        'www.youtube.com',
        'youtu.be',
        'm.youtube.com',
        'googlevideo.com',
        'ytimg.com',
        'i.ytimg.com',
        'yt3.ggpht.com',
        'youtube-nocookie.com',
        'music.youtube.com',
        'googleapis.com',
        'gstatic.com',
        'google.com',
        'ggpht.com',
        'googleusercontent.com',
        'gvt1.com',
        'gvt2.com',
        'gvt3.com',
      ]);
    }
    
    // حذف duplicate
    final uniqueDomains = criticalDomains.toSet().toList();
    
    // دریافت Address-List موجود
    final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
    final existingAddresses = <String>{};
    for (final entry in allAddressList) {
      if (entry['list']?.toString() == addressListName) {
        existingAddresses.add(entry['address']?.toString() ?? '');
      }
    }
    
    // Resolve کردن هر دامنه و اضافه کردن IPها - مطابق با الگوی تلگرام
    for (final domain in uniqueDomains) {
      try {
        // تشخیص platform از domain
        String? detectedPlatform;
        final domainLower = domain.toLowerCase();
        if (domainLower.contains('telegram') || domainLower.contains('t.me')) {
          detectedPlatform = 'telegram';
        } else if (domainLower.contains('facebook') || domainLower.contains('fb.com') || domainLower.contains('fbcdn')) {
          detectedPlatform = 'facebook';
        } else if (domainLower.contains('instagram') || domainLower.contains('cdninstagram')) {
          detectedPlatform = 'instagram';
        } else if (domainLower.contains('tiktok')) {
          detectedPlatform = 'tiktok';
        } else if (domainLower.contains('whatsapp')) {
          detectedPlatform = 'whatsapp';
        } else if (domainLower.contains('youtube') || domainLower.contains('googlevideo')) {
          detectedPlatform = 'youtube';
        }
        
        // Resolve کردن دامنه با retry logic (برای اطمینان از موفقیت)
        String? resolvedIp;
        int retryCount = 0;
        const maxRetries = 3;
        
        while (retryCount < maxRetries && resolvedIp == null) {
          try {
            final resolveResult = await _client!.talk([
              '/resolve',
              '=type=A',
              '=host=$domain',
            ]);
            
            if (resolveResult.isNotEmpty) {
              final ip = resolveResult[0]['data']?.toString() ?? '';
              if (_isValidIP(ip)) {
                resolvedIp = ip;
              }
            }
          } catch (e) {
            // اگر خطا داد، retry کن
            retryCount++;
            if (retryCount < maxRetries) {
              await Future.delayed(Duration(milliseconds: 500 * retryCount));
            }
          }
          
          if (resolvedIp == null && retryCount < maxRetries) {
            retryCount++;
            await Future.delayed(Duration(milliseconds: 500 * retryCount));
          }
        }
        
        if (resolvedIp != null && !existingAddresses.contains(resolvedIp)) {
          try {
            final comment = detectedPlatform != null
                ? 'SM-Filter:Platform=$detectedPlatform|Resolved - $domain'
                : 'SM-Filter:Resolved|Resolved - $domain';
            
            await _client!.talk([
              '/ip/firewall/address-list/add',
              '=list=$addressListName',
              '=address=$resolvedIp',
              '=comment=$comment',
            ]);
            existingAddresses.add(resolvedIp);
            resolvedCount++;
            print('[DEBUG] _resolveAndAddDomainsToAddressList: Resolved $domain -> $resolvedIp');
          } catch (e) {
            // ممکن است duplicate باشد - continue
            print('[DEBUG] _resolveAndAddDomainsToAddressList: Error adding $resolvedIp for $domain: $e');
          }
        } else if (resolvedIp == null) {
          print('[DEBUG] _resolveAndAddDomainsToAddressList: Failed to resolve $domain after $maxRetries retries');
        }
      } catch (e) {
        // ignore resolve errors - continue with next domain
      }
    }
    
    return resolvedCount;
  }

  /// ایجاد Address-List فقط برای IPهای ثابت (نه CDN)
  /// این برای IPهای شناخته شده و ثابت استفاده می‌شود
  Future<int> _createAddressListForStaticIPs(
    List<String> platforms,
    String addressListName,
  ) async {
    int addedCount = 0;
    final socialMediaData = await _getSocialMediaAddresses();
    final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
    
    // مجموعه‌ای از IPهایی که قبلاً اضافه شده‌اند
    final existingAddresses = <String>{};
    for (final entry in allAddressList) {
      final list = entry['list']?.toString() ?? '';
      final address = entry['address']?.toString() ?? '';
      if (list == addressListName) {
        existingAddresses.add(address);
      }
    }
    
    for (final platform in platforms) {
      final platformLower = platform.toLowerCase();
      print('[DEBUG] _createAddressListForStaticIPs: Processing platform: $platformLower');
      if (!socialMediaData.containsKey(platformLower)) {
        print('[DEBUG] _createAddressListForStaticIPs: Platform $platformLower not found in socialMediaData');
        continue;
      }
      
      final addresses = socialMediaData[platformLower]!;
      print('[DEBUG] _createAddressListForStaticIPs: Found ${addresses.length} addresses for $platformLower');
      
      int platformAddedCount = 0;
      for (final address in addresses) {
        try {
          // فقط IP range ها و IPهای مستقیم را اضافه کن (نه دامنه‌ها)
          if (address.contains('/') || RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(address)) {
            if (!existingAddresses.contains(address)) {
              // اضافه کردن comment برای تشخیص پلتفرم
              final comment = 'SM-Filter:Platform=$platformLower|Block $platformLower - static IP';
              await _client!.talk([
                '/ip/firewall/address-list/add',
                '=list=$addressListName',
                '=address=$address',
                '=comment=$comment',
              ]);
              existingAddresses.add(address);
              addedCount++;
              platformAddedCount++;
            } else {
              print('[DEBUG] _createAddressListForStaticIPs: Address $address already exists, skipping');
            }
          }
        } catch (e) {
          print('[DEBUG] _createAddressListForStaticIPs: Error adding address $address for $platformLower: $e');
          // continue with next address
        }
      }
      print('[DEBUG] _createAddressListForStaticIPs: Added $platformAddedCount addresses for $platformLower');
    }
    
    return addedCount;
  }

  /// ایجاد Raw Rule برای Address-List (فقط Raw Rules، نه Filter Rules)
  Future<int> _createAddressListRawRule(
    String deviceIp,
    String? deviceMac,
    String addressListName,
    List<String> platforms,
    String? deviceName,
  ) async {
    int rulesAdded = 0;
    
    // بررسی وجود Raw Rule قبلی
    try {
      final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
      for (final rule in allRawRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        
        if (srcAddress == deviceIp &&
            dstAddressList == addressListName &&
            comment.contains('Block social')) {
          final ruleId = rule['.id']?.toString();
          if (ruleId != null) {
            try {
              await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
            } catch (e) {
              // continue
            }
          }
        }
      }
    } catch (e) {
      // continue
    }
    
    // ایجاد Raw Rule برای drop کردن ترافیک به Address-List
    try {
      // استفاده از فرمت ساده‌تر برای comment (بدون کاراکترهای خاص)
      final commentText = 'SM-Filter:Platforms=${platforms.join(",")}';
      print('[DEBUG] _createAddressListRawRule: Creating Raw Rule with comment: "$commentText"');
      
      final rawRuleParams = <String, String>{
        'chain': 'prerouting',
        'src-address': deviceIp,
        'dst-address-list': addressListName,
        'action': 'drop',
        'comment': commentText,
      };

      if (deviceMac != null && deviceMac.isNotEmpty) {
        rawRuleParams['src-mac-address'] = deviceMac;
      }

      final rawCommand = <String>['/ip/firewall/raw/add'];
      rawRuleParams.forEach((key, value) {
        rawCommand.add('=$key=$value');
      });
      
      print('[DEBUG] _createAddressListRawRule: Raw command: $rawCommand');

      final result = await _client!.talk(rawCommand);
      print('[DEBUG] _createAddressListRawRule: Result: $result');
      
      // بررسی مجدد Raw Rule برای اطمینان از اضافه شدن comment
      await Future.delayed(const Duration(milliseconds: 500));
      final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
      for (final rule in allRawRules) {
        final srcAddr = rule['src-address']?.toString() ?? '';
        final dstList = rule['dst-address-list']?.toString() ?? '';
        if (srcAddr == deviceIp && dstList == addressListName) {
          final ruleComment = rule['comment']?.toString() ?? '';
          print('[DEBUG] _createAddressListRawRule: Verified Raw Rule comment: "$ruleComment"');
          break;
        }
      }
      
      rulesAdded++;
    } catch (e) {
      // اگر raw rule خطا داد، خطا را throw می‌کنیم
      throw Exception('خطا در ایجاد Raw Rule: $e');
    }

    return rulesAdded;
  }

  /// ایجاد Firewall Rule برای Address-List (backup برای Raw Rule)
  Future<int> _createAddressListFirewallRule(
    String deviceIp,
    String? deviceMac,
    String addressListName,
    String? deviceName,
  ) async {
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);
    bool ruleExists = false;
    String? existingRuleId;
    
    for (final rule in allRules) {
      final srcAddress = rule['src-address']?.toString() ?? '';
      final dstAddressList = rule['dst-address-list']?.toString() ?? '';
      final comment = rule['comment']?.toString() ?? '';
      
      // بررسی بدون comment (چون comment ممکن است خالی باشد)
      if (srcAddress == deviceIp && dstAddressList == addressListName) {
        ruleExists = true;
        existingRuleId = rule['.id']?.toString();
        break;
      }
    }
    
    if (ruleExists && existingRuleId != null) {
      // Rule از قبل وجود دارد، نیازی به ایجاد مجدد نیست
      return 0;
    }
    
    // پیدا کردن اولین rule در chain forward برای قرار دادن rule جدید در اول لیست
    String? firstRuleId;
    try {
      final forwardRules = allRules.where((r) => r['chain']?.toString() == 'forward').toList();
      if (forwardRules.isNotEmpty) {
        firstRuleId = forwardRules[0]['.id']?.toString();
      }
    } catch (e) {
      // ignore
    }
    
    try {
      final ruleParams = <String, String>{
        'chain': 'forward',
        'src-address': deviceIp,
        'dst-address-list': addressListName,
        'action': 'drop',
        'comment': 'SM-Filter:Address-List-Backup|Block social - Address-List backup - Device: ${deviceName ?? deviceIp}',
      };
      
      if (deviceMac != null && deviceMac.isNotEmpty) {
        ruleParams['src-mac-address'] = deviceMac;
      }
      
      if (firstRuleId != null) {
        ruleParams['place-before'] = firstRuleId;
      }
      
      final addCommand = <String>['/ip/firewall/filter/add'];
      ruleParams.forEach((key, value) {
        addCommand.add('=$key=$value');
      });
      
      await _client!.talk(addCommand);
      return 1;
    } catch (e) {
      print('[DEBUG] _createAddressListFirewallRule: Error: $e');
      return 0;
    }
  }

  /// ایجاد Firewall Rule برای device-specific blocking (قدیمی - برای سازگاری)
  Future<int> _createFirewallRuleForDevice(
    String deviceIp,
    String? deviceMac,
    String addressListName,
    List<String> platforms,
    String? deviceName,
  ) async {
    // بررسی وجود rule قبلی
    final allRules = await _client!.talk(['/ip/firewall/filter/print']);
    bool ruleExists = false;
    String? existingRuleId;

    for (final rule in allRules) {
      final srcAddress = rule['src-address']?.toString() ?? '';
      final dstAddressList = rule['dst-address-list']?.toString() ?? '';
      final comment = rule['comment']?.toString() ?? '';
      
      if (srcAddress == deviceIp && 
          dstAddressList == addressListName &&
          comment.contains('Block social')) {
        ruleExists = true;
        existingRuleId = rule['.id']?.toString();
        break;
      }
    }

    // اگر rule وجود دارد، حذفش کن و دوباره بساز (برای به‌روزرسانی platforms)
    if (ruleExists && existingRuleId != null) {
      try {
        await _client!.talk(['/ip/firewall/filter/remove', '=.id=$existingRuleId']);
      } catch (e) {
        // continue
      }
    }

    // پیدا کردن اولین rule در chain forward برای قرار دادن rule جدید در اول لیست
    String? firstRuleId;
    try {
      final forwardRules = allRules.where((r) => r['chain']?.toString() == 'forward').toList();
      if (forwardRules.isNotEmpty) {
        firstRuleId = forwardRules[0]['.id']?.toString();
      }
    } catch (e) {
      // ignore
    }

    // ایجاد rule جدید - استفاده از Raw Rules برای کارایی بهتر
    int rulesAdded = 0;
    
    // 1. Raw Rule برای drop کردن ترافیک به Address-List (سریع‌تر)
    try {
      final rawRuleParams = <String, String>{
        'chain': 'prerouting',
        'src-address': deviceIp,
        'dst-address-list': addressListName,
        'action': 'drop',
        'comment': 'SM-Filter:Platforms=${platforms.join(",")}|Block social - Platforms: ${platforms.join(", ")} - Device: ${deviceName ?? deviceIp}',
      };

      if (deviceMac != null && deviceMac.isNotEmpty) {
        rawRuleParams['src-mac-address'] = deviceMac;
      }

      final rawCommand = <String>['/ip/firewall/raw/add'];
      rawRuleParams.forEach((key, value) {
        rawCommand.add('=$key=$value');
      });

      await _client!.talk(rawCommand);
      rulesAdded++;
    } catch (e) {
      // اگر raw rule خطا داد، از filter rule استفاده می‌کنیم
    }

    // 2. Filter Rule (backup) - در اول لیست قرار می‌دهیم
    try {
      final ruleParams = <String, String>{
        'chain': 'forward',
        'src-address': deviceIp,
        'dst-address-list': addressListName,
        'action': 'drop',
        'comment': 'SM-Filter:Platforms=${platforms.join(",")}|Block social - Platforms: ${platforms.join(", ")} - Device: ${deviceName ?? deviceIp}',
      };

      if (deviceMac != null && deviceMac.isNotEmpty) {
        ruleParams['src-mac-address'] = deviceMac;
      }

      // قرار دادن rule در اول لیست
      if (firstRuleId != null) {
        ruleParams['place-before'] = firstRuleId;
      }

      final addCommand = <String>['/ip/firewall/filter/add'];
      ruleParams.forEach((key, value) {
        addCommand.add('=$key=$value');
      });

      await _client!.talk(addCommand);
      rulesAdded++;
    } catch (e) {
      if (rulesAdded == 0) {
        throw Exception('خطا در ایجاد Firewall Rule: $e');
      }
    }

    return rulesAdded;
  }


  /// اضافه کردن DNS Static Entries (redirect دامنه‌ها به 127.0.0.1)
  Future<int> _addDNSStaticEntries(
    List<String> platforms,
    Map<String, List<String>> socialMediaData,
  ) async {
    int addedCount = 0;
    final mainDomains = {
      'youtube': [
        'youtube.com', '*.youtube.com', 'www.youtube.com', 'youtu.be', 'm.youtube.com',
        'googlevideo.com', '*.googlevideo.com', 'ytimg.com', '*.ytimg.com',
        'i.ytimg.com', 'yt3.ggpht.com', 'youtube-nocookie.com',
        'music.youtube.com', 'youtubeeducation.com',
      ],
      'instagram': [
        'instagram.com', 'www.instagram.com', 'm.instagram.com',
        'api.instagram.com', 'i.instagram.com', 'graph.instagram.com',
        'cdninstagram.com', 'instagr.am', 'ig.me',
        'fbcdn.net', // CDN مشترک با فیسبوک
        'instagram.net',
      ],
      'facebook': [
        'facebook.com', '*.facebook.com', 'www.facebook.com', 'fb.com', '*.fb.com',
        'www.fb.com', 'm.facebook.com', 'mobile.facebook.com', 'touch.facebook.com',
        'login.facebook.com', 'graph.facebook.com', 'graph-api.facebook.com',
        'fbcdn.net', '*.fbcdn.net', 'static.ak.fbcdn.net', 'scontent.xx.fbcdn.net',
        'connect.facebook.net', 'apps.facebook.com', 'upload.facebook.com',
        'web.facebook.com', 'web-fallback.facebook.com', 'edge-chat.facebook.com',
        'api.facebook.com', 'facebook.net', 'fbstatic.com', 'fbsbx.com', '*.fbsbx.com',
        'fbpigeon.com', 'facebook-hardware.com', 'messenger.com', '*.messenger.com',
        'www.messenger.com', 'secure.facebook.com', 'static.xx.fbcdn.net',
        'scontent-a.xx.fbcdn.net', 'scontent-b.xx.fbcdn.net', 'scontent-c.xx.fbcdn.net',
        'scontent-d.xx.fbcdn.net', 'scontent-e.xx.fbcdn.net', 'scontent-f.xx.fbcdn.net',
        'fbexternal-a.akamaihd.net', 'fbexternal-b.akamaihd.net',
        // Facebook IP ranges (AS32934 - Meta/Facebook) - رنج‌های کامل طبق راهنما
        '31.13.24.0/21',    // Facebook IP range (جدید)
        '31.13.64.0/18',    // Facebook IP range
        '45.64.40.0/22',    // Facebook IP range (جدید)
        '57.144.16.0/22',   // Facebook IP range (جدید)
        '66.220.0.0/16',    // Facebook IP range (بزرگتر)
        '69.63.176.0/20',   // Facebook IP range
        '69.171.0.0/16',    // Facebook IP range (بزرگتر)
        '74.119.76.0/22',   // Facebook IP range
        '102.132.96.0/20',  // Facebook IP range (جدید)
        '103.4.96.0/22',    // Facebook IP range
        '129.134.0.0/16',   // Facebook IP range
        '147.75.208.0/20',  // Facebook IP range (جدید)
        '157.240.0.0/16',   // Facebook IP range (کل range)
        '173.252.64.0/18',  // Facebook IP range
        '179.60.192.0/22',  // Facebook IP range
        '185.60.216.0/22',  // Facebook IP range
        '185.89.216.0/22',  // Facebook IP range (جدید)
        '204.15.20.0/22',   // Facebook IP range
      ],
      'tiktok': [
        'tiktok.com', 'www.tiktok.com', 'tiktokcdn.com', 'tiktokv.com',
        'tiktok.net', 'v.tiktok.net', 'v.tiktok.com',
        'musical.ly', 'muscdn.com',
        'ibyteimg.com', 'bytecdn.cn', 'byted.org',
      ],
      'twitter': [
        'twitter.com', '*.twitter.com', 'www.twitter.com', 'twimg.com', '*.twimg.com',
        't.co', 'twitpic.com',
      ],
      'telegram': [
        'telegram.org', '*.telegram.org', 'web.telegram.org', 't.me', 'telegram.me',
        'telesco.pe', 'tg.dev', 'core.telegram.org',
      ],
      'whatsapp': [
        'whatsapp.com', '*.whatsapp.com', 'web.whatsapp.com', 'whatsapp.net', 'wa.me',
        'wl.co', 'whatsapp.org', 'whatsapp.info', 'whatsapp.tv',
        'whatsappbrand.com',
      ],
      'snapchat': [
        'snapchat.com', '*.snapchat.com', 'www.snapchat.com', 'snap-dev.net', 'sc-cdn.net',
      ],
      'linkedin': [
        'linkedin.com', '*.linkedin.com', 'www.linkedin.com', 'licdn.com',
      ],
    };

    final allDNSStatic = await _client!.talk(['/ip/dns/static/print']);

    for (final platform in platforms) {
      final platformLower = platform.toLowerCase();
      if (!mainDomains.containsKey(platformLower)) continue;

      final domains = mainDomains[platformLower]!;

      for (final domain in domains) {
        try {
          // فقط دامنه‌ها را اضافه کن (نه IP ranges و نه wildcard)
          // MikroTik wildcard را در DNS static entries پشتیبانی نمی‌کند
          if (domain.contains('/') || 
              RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(domain) ||
              domain.startsWith('*.')) {
            continue; // IP ranges و wildcard را skip کن
          }
          
          // بررسی وجود entry (پشتیبانی از 0.0.0.0 و 127.0.0.1)
          bool exists = false;
          for (final entry in allDNSStatic) {
            final name = entry['name']?.toString() ?? '';
            final address = entry['address']?.toString() ?? '';
            if (name == domain && (address == '0.0.0.0' || address == '127.0.0.1')) {
              exists = true;
              break;
            }
          }

          if (!exists) {
            // استفاده از 127.0.0.1 (0.0.0.0 در برخی RouterOS نسخه‌ها کار نمی‌کند)
            await _client!.talk([
              '/ip/dns/static/add',
              '=name=$domain',
              '=address=127.0.0.1',
              '=comment=SM-Filter:Platform=$platformLower|Block $platformLower - DNS',
            ]);
            addedCount++;
            print('[DEBUG] _addDNSStaticEntries: Added DNS static entry for $platformLower: $domain');
          }
        } catch (e) {
          print('[DEBUG] _addDNSStaticEntries: Error adding DNS static entry for $domain: $e');
          // continue with next domain
        }
      }
    }

    // پاک کردن DNS cache
    try {
      await _client!.talk(['/ip/dns/cache/flush']);
    } catch (e) {
      // ignore
    }

    return addedCount;
  }

  /// دریافت دامنه‌ها و IP های شبکه‌های اجتماعی
  Future<Map<String, List<String>>> _getSocialMediaAddresses() async {
    return {
      'youtube': [
        'youtube.com',
        'www.youtube.com',
        'youtu.be',
        'm.youtube.com',
        'googlevideo.com',
        'ytimg.com',
        'i.ytimg.com',
        'yt3.ggpht.com',
        'youtube-nocookie.com',
        'music.youtube.com',
        'youtubeeducation.com',
        'googleapis.com',
        'gstatic.com',
        'google.com',
        'ggpht.com',
        'googleusercontent.com',
        'gvt1.com',
        'gvt2.com',
        'gvt3.com',
        // YouTube IP ranges (AS15169 - Google)
        '142.250.0.0/16',   // Google IP range
        '142.250.191.0/24', // Google IP range
        '172.217.0.0/16',   // Google IP range
        '173.194.0.0/16',   // Google IP range
        '216.58.0.0/16',    // Google IP range
      ],
      'instagram': [
        'instagram.com',
        'www.instagram.com',
        'm.instagram.com',
        'api.instagram.com',
        'i.instagram.com',
        'graph.instagram.com',
        'cdninstagram.com',
        'instagr.am',
        'ig.me',
        'fbcdn.net', // CDN مشترک با فیسبوک
        'instagram.net',
        // Facebook/Instagram IP ranges (AS32934 - Meta/Facebook) - رنج‌های کامل طبق راهنما
        '31.13.24.0/21',    // Facebook/Instagram IP range (جدید)
        '31.13.64.0/18',    // Facebook/Instagram IP range
        '45.64.40.0/22',    // Facebook/Instagram IP range (جدید)
        '57.144.16.0/22',   // Facebook/Instagram IP range (جدید)
        '66.220.0.0/16',    // Facebook/Instagram IP range (بزرگتر)
        '69.63.176.0/20',   // Facebook/Instagram IP range
        '69.171.0.0/16',    // Facebook/Instagram IP range (بزرگتر)
        '74.119.76.0/22',   // Facebook/Instagram IP range
        '102.132.96.0/20',  // Facebook/Instagram IP range (جدید)
        '103.4.96.0/22',    // Facebook/Instagram IP range
        '129.134.0.0/16',   // Facebook/Instagram IP range
        '147.75.208.0/20',  // Facebook/Instagram IP range (جدید)
        '157.240.0.0/16',   // Facebook/Instagram IP range (کل range)
        '173.252.64.0/18',  // Facebook/Instagram IP range
        '179.60.192.0/22',  // Facebook/Instagram IP range
        '185.60.216.0/22',  // Facebook/Instagram IP range
        '185.89.216.0/22',  // Facebook/Instagram IP range (جدید)
        '204.15.20.0/22',   // Facebook/Instagram IP range
      ],
      'facebook': [
        'facebook.com',
        'www.facebook.com',
        'm.facebook.com',
        'fb.com',
        'www.fb.com',
        'login.facebook.com',
        'graph.facebook.com',
        'connect.facebook.net',
        'fbcdn.net',
        'static.ak.fbcdn.net',
        'scontent.xx.fbcdn.net',
        'apps.facebook.com',
        'upload.facebook.com',
        'web.facebook.com',
        'web-fallback.facebook.com',
        'edge-chat.facebook.com',
        'api.facebook.com',
        'facebook.net',
        'fbstatic.com',
        'fbsbx.com',
        'fbpigeon.com',
        'facebook-hardware.com',
        // Facebook IP ranges (AS32934 - Meta/Facebook) - رنج‌های کامل طبق راهنما
        '31.13.24.0/21',    // Facebook IP range (جدید)
        '31.13.64.0/18',    // Facebook IP range
        '45.64.40.0/22',    // Facebook IP range (جدید)
        '57.144.16.0/22',   // Facebook IP range (جدید)
        '66.220.0.0/16',    // Facebook IP range (بزرگتر)
        '69.63.176.0/20',   // Facebook IP range
        '69.171.0.0/16',    // Facebook IP range (بزرگتر)
        '74.119.76.0/22',   // Facebook IP range
        '102.132.96.0/20',  // Facebook IP range (جدید)
        '103.4.96.0/22',    // Facebook IP range
        '129.134.0.0/16',   // Facebook IP range
        '147.75.208.0/20',  // Facebook IP range (جدید)
        '157.240.0.0/16',   // Facebook IP range (کل range)
        '173.252.64.0/18',  // Facebook IP range
        '179.60.192.0/22',  // Facebook IP range
        '185.60.216.0/22',  // Facebook IP range
        '185.89.216.0/22',  // Facebook IP range (جدید)
        '204.15.20.0/22',   // Facebook IP range
      ],
      'tiktok': [
        'tiktok.com',
        'www.tiktok.com',
        'tiktokcdn.com',
        'tiktokv.com',
        'tiktok.net',
        'v.tiktok.net',
        'v.tiktok.com',
        'tiktok.org',
        'musical.ly', // نام قدیمی TikTok
        'muscdn.com',
        'ibyteimg.com',
        'bytecdn.cn',
        'byted.org',
        'byteoversea.com',
        // TikTok IP ranges
        '13.107.42.0/24',     // TikTok IP range
        '20.42.64.0/24',      // TikTok IP range
        '20.190.128.0/24',    // TikTok IP range
      ],
      'twitter': [
        'twitter.com',
        'www.twitter.com',
        'twimg.com',
        't.co',
        'twitpic.com',
      ],
      'telegram': [
        'telegram.org',
        'web.telegram.org',
        't.me',
        'telegram.me',
        'telesco.pe',
        'tg.dev',
        'core.telegram.org',
        // Telegram IP ranges (AS62041)
        '149.154.160.0/20',  // Telegram IP range
        '149.154.160.0/23',  // Telegram IP range
        '149.154.162.0/23',  // Telegram IP range
        '149.154.164.0/23',  // Telegram IP range
        '149.154.166.0/23',  // Telegram IP range
        '91.108.4.0/22',     // Telegram IP range
        '91.108.8.0/22',     // Telegram IP range
        '91.108.12.0/22',    // Telegram IP range
        '91.108.16.0/22',    // Telegram IP range
        '91.108.20.0/22',    // Telegram IP range
        '91.108.56.0/22',    // Telegram IP range
      ],
      'whatsapp': [
        'whatsapp.com',
        'web.whatsapp.com',
        'whatsapp.net',
        'wa.me',
        'wl.co',
        'whatsapp.org',
        'whatsapp.info',
        'whatsapp.tv',
        'whatsappbrand.com',
        'whatsapp-plus.me',
        'whatsapp-plus.net',
        'whatsapp-plus.info',
        // WhatsApp IP ranges (AS32934 - Meta/Facebook)
        '157.240.0.0/16',    // WhatsApp IP range (Facebook)
        '31.13.0.0/16',      // WhatsApp IP range (Facebook)
        '31.13.64.0/18',     // WhatsApp IP range (Facebook)
      ],
      'snapchat': [
        'snapchat.com',
        'www.snapchat.com',
        'snap-dev.net',
        'sc-cdn.net',
      ],
      'linkedin': [
        'linkedin.com',
        'www.linkedin.com',
        'licdn.com',
      ],
    };
  }

  /// Resolve و اضافه کردن دامنه‌های مهم برای اینستاگرام و فیسبوک
  Future<int> _resolveAndAddCriticalDomains(
    List<String> platforms,
    String addressListName,
  ) async {
    int addedCount = 0;
    final criticalDomains = <String>[];
    
    if (platforms.contains('instagram')) {
      criticalDomains.addAll([
        'instagram.com',
        'www.instagram.com',
        'm.instagram.com',
        'cdninstagram.com',
        'graph.instagram.com',
        'api.instagram.com',
        'i.instagram.com',
        'scontent.cdninstagram.com',
        'fbcdn.net',
      ]);
    }
    
    if (platforms.contains('facebook')) {
      criticalDomains.addAll([
        'facebook.com',
        'www.facebook.com',
        'fb.com',
        'fbcdn.net',
        'connect.facebook.net',
        'static.xx.fbcdn.net',
        'scontent.xx.fbcdn.net',
      ]);
    }
    
    final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
    final existingAddresses = <String>{};
    for (final entry in allAddressList) {
      if (entry['list']?.toString() == addressListName) {
        existingAddresses.add(entry['address']?.toString() ?? '');
      }
    }
    
    for (final domain in criticalDomains) {
      try {
        // Resolve کردن دامنه
        final resolveResult = await _client!.talk([
          '/resolve',
          '=type=A',
          '=host=$domain',
        ]);
        
        if (resolveResult.isNotEmpty) {
          final ip = resolveResult[0]['data']?.toString() ?? '';
          if (_isValidIP(ip) && !existingAddresses.contains(ip)) {
            await _client!.talk([
              '/ip/firewall/address-list/add',
              '=list=$addressListName',
              '=address=$ip',
              '=comment=Block resolved - $domain',
            ]);
            existingAddresses.add(ip);
            addedCount++;
          }
        }
      } catch (e) {
        // continue with next domain
      }
    }
    
    return addedCount;
  }

  /// فعال‌سازی فیلترینگ شبکه‌های اجتماعی برای یک دستگاه (رویکرد پیشرفته - فقط اپلیکیشن‌ها)
  /// روش اصلی: Resolve دینامیک + Address-List + TLS-SNI (tls-host) + بلاک DNS عمومی + بلاک DoH/DoT
  /// این روش فقط اپلیکیشن‌ها را فیلتر می‌کند نه وبسایت‌ها
  Future<Map<String, dynamic>> enableSocialMediaFilter(
    String deviceIp, {
    String? deviceMac,
    String? deviceName,
    List<String>? platforms,
    bool enableDNSBlocking = false, // غیرفعال - فقط برای اپلیکیشن‌ها
    bool enableAddressList = true,
    bool enableFirewallRule = false, // غیرفعال - نباید Filter Rules ایجاد شود
    bool blockDNSBypass = true,
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    if (deviceIp.isEmpty) {
      throw Exception('آدرس IP دستگاه الزامی است');
    }

    // لیست پیش‌فرض شبکه‌های اجتماعی
    final defaultPlatforms = ['tiktok', 'facebook', 'instagram', 'telegram', 'youtube', 'whatsapp'];
    final selectedPlatforms = platforms ?? defaultPlatforms;

    final results = <String, dynamic>{
      'success': true,
      'device_ip': deviceIp,
      'platforms': selectedPlatforms,
      'dns_entries_added': 0,
      'address_list_entries_added': 0,
      'firewall_rules_added': 0,
      'dns_bypass_rules_added': 0,
      'resolved_domains': 0,
      'old_rules_cleaned': 0,
      'errors': <String>[],
    };

    try {
      // 0. پاکسازی rules قدیمی برای همه پلتفرم‌های انتخاب شده قبل از ایجاد rules جدید
      int totalCleaned = 0;
      for (final platform in selectedPlatforms) {
        final cleanedCount = await _cleanupOldPlatformRules(deviceIp, platform);
        totalCleaned += cleanedCount;
      }
      results['old_rules_cleaned'] = totalCleaned;

      // 1. فعال‌سازی DNS redirect (اجباری کردن استفاده از DNS داخلی)
      try {
        await _client!.talk(['/ip/dns/set', '=allow-remote-requests=yes']);
        
        // دریافت IP interface داخلی روتر (LAN interface)
        String? routerLanIp;
        try {
          // پیدا کردن IP interface که در همان subnet با deviceIp است
          final interfaces = await _client!.talk(['/ip/address/print']);
          final deviceParts = deviceIp.split('.');
          if (deviceParts.length == 4) {
            final subnetPrefix = '${deviceParts[0]}.${deviceParts[1]}.${deviceParts[2]}.';
            for (final iface in interfaces) {
              final address = iface['address']?.toString() ?? '';
              if (address.contains('/')) {
                final ip = address.split('/')[0];
                if (ip.startsWith(subnetPrefix)) {
                  routerLanIp = ip;
                  break;
                }
              }
            }
          }
        } catch (e) {
          // ignore
        }
        
        // اگر پیدا نشد، از connection host استفاده کن
        routerLanIp ??= _connection?.host;
        
        if (routerLanIp == null || routerLanIp.isEmpty) {
          results['errors'].add('نمی‌توان IP روتر را تشخیص داد');
        } else {
          // NAT rule برای redirect DNS به روتر (فقط برای این دستگاه)
          final natRules = await _client!.talk(['/ip/firewall/nat/print']);
          bool dnsRedirectExists = false;
          
          for (final rule in natRules) {
            final chain = rule['chain']?.toString() ?? '';
            final dstPort = rule['dst-port']?.toString() ?? '';
            final action = rule['action']?.toString() ?? '';
            final srcAddress = rule['src-address']?.toString() ?? '';
            final comment = rule['comment']?.toString() ?? '';
            
            if (chain == 'dstnat' && 
                (dstPort == '53' || dstPort == '853') &&
                action == 'dst-nat' &&
                srcAddress == deviceIp &&
                comment.contains('Force DNS')) {
              dnsRedirectExists = true;
              break;
            }
          }
          
          if (!dnsRedirectExists) {
            // Redirect UDP DNS برای این دستگاه
            await _client!.talk([
              '/ip/firewall/nat/add',
              '=chain=dstnat',
              '=protocol=udp',
              '=dst-port=53',
              '=src-address=$deviceIp',
              '=action=dst-nat',
              '=to-addresses=$routerLanIp',
              '=to-ports=53',
              '=comment=Force DNS to router - Device: $deviceIp',
            ]);
            
            // Redirect TCP DNS برای این دستگاه
            await _client!.talk([
              '/ip/firewall/nat/add',
              '=chain=dstnat',
              '=protocol=tcp',
              '=dst-port=53',
              '=src-address=$deviceIp',
              '=action=dst-nat',
              '=to-addresses=$routerLanIp',
              '=to-ports=53',
              '=comment=Force DNS to router - Device: $deviceIp',
            ]);
          }
        }
      } catch (e) {
        results['errors'].add('خطا در تنظیم DNS redirect: $e');
      }

      // 2. بلاک کردن DNS عمومی (8.8.8.8, 1.1.1.1, etc.) - فقط برای این دستگاه
      if (blockDNSBypass) {
        try {
          final publicDNSList = [
            '8.8.8.8', '8.8.4.4', // Google DNS
            '1.1.1.1', '1.0.0.1', // Cloudflare DNS
            '9.9.9.9', '149.112.112.112', // Quad9
            '208.67.222.222', '208.67.220.220', // OpenDNS
          ];
          
          final allRules = await _client!.talk(['/ip/firewall/filter/print']);
          int blockedCount = 0;
          
          for (final dnsIp in publicDNSList) {
            bool ruleExists = false;
            for (final rule in allRules) {
              final srcAddress = rule['src-address']?.toString() ?? '';
              final dstAddress = rule['dst-address']?.toString() ?? '';
              final comment = rule['comment']?.toString() ?? '';
              
              if (srcAddress == deviceIp &&
                  dstAddress == dnsIp &&
                  comment.contains('Block public DNS')) {
                ruleExists = true;
                break;
              }
            }
            
            if (!ruleExists) {
              try {
                await _client!.talk([
                  '/ip/firewall/filter/add',
                  '=chain=forward',
                  '=src-address=$deviceIp',
                  '=dst-address=$dnsIp',
                  '=action=drop',
                  '=comment=Block public DNS - $dnsIp - Device: $deviceIp',
                ]);
                blockedCount++;
              } catch (e) {
                // continue
              }
            }
          }
          
          // بلاک پورت DoT (853)
          bool dotRuleExists = false;
          for (final rule in allRules) {
            final srcAddress = rule['src-address']?.toString() ?? '';
            final protocol = rule['protocol']?.toString() ?? '';
            final dstPort = rule['dst-port']?.toString() ?? '';
            final comment = rule['comment']?.toString() ?? '';
            
            if (srcAddress == deviceIp &&
                protocol == 'tcp' &&
                dstPort == '853' &&
                comment.contains('Block DoT')) {
              dotRuleExists = true;
              break;
            }
          }
          
          if (!dotRuleExists) {
            try {
              await _client!.talk([
                '/ip/firewall/filter/add',
                '=chain=forward',
                '=protocol=tcp',
                '=dst-port=853',
                '=src-address=$deviceIp',
                '=action=drop',
                '=comment=Block DoT - Device: $deviceIp',
              ]);
              blockedCount++;
            } catch (e) {
              // continue
            }
          }
          
          // بلاک DoH (DNS over HTTPS) با استفاده از TLS-SNI
          // DoH از HTTPS استفاده می‌کند، پس باید دامنه‌های DoH را با TLS-SNI بلاک کنیم
          final dohHosts = [
            'dns.google',           // Google DoH
            'dns64.dns.google',     // Google DoH IPv6
            'cloudflare-dns.com',   // Cloudflare DoH
            '1dot1dot1dot1.cloudflare-dns.com', // Cloudflare DoH
            'dns.quad9.net',        // Quad9 DoH
            'dns.opendns.com',      // OpenDNS DoH
            'doh.opendns.com',      // OpenDNS DoH
          ];
          
          int dohBlockedCount = 0;
          for (final dohHost in dohHosts) {
            bool dohRuleExists = false;
            for (final rule in allRules) {
              final srcAddress = rule['src-address']?.toString() ?? '';
              final tlsHost = rule['tls-host']?.toString() ?? '';
              final comment = rule['comment']?.toString() ?? '';
              
              if (srcAddress == deviceIp &&
                  tlsHost == dohHost &&
                  comment.contains('Block DoH')) {
                dohRuleExists = true;
                break;
              }
            }
            
            if (!dohRuleExists) {
              try {
                await _client!.talk([
                  '/ip/firewall/filter/add',
                  '=chain=forward',
                  '=protocol=tcp',
                  '=dst-port=443',
                  '=src-address=$deviceIp',
                  '=tls-host=$dohHost',
                  '=action=drop',
                  '=comment=Block DoH - $dohHost - Device: $deviceIp',
                ]);
                dohBlockedCount++;
                print('[DEBUG] enableSocialMediaFilter: Blocked DoH host: $dohHost');
              } catch (e) {
                print('[DEBUG] enableSocialMediaFilter: Error blocking DoH host $dohHost: $e');
                // continue
              }
            }
          }
          
          results['dns_bypass_rules_added'] = blockedCount + dohBlockedCount;
        } catch (e) {
          results['errors'].add('خطا در بلاک DNS عمومی: $e');
        }
      }

      // 3. ایجاد Address-List با Resolve دینامیک (روش اصلی برای اپلیکیشن‌ها)
      // این روش IPهای واقعی را resolve می‌کند و به Address-List اضافه می‌کند
      if (enableAddressList) {
        try {
          const addressListName = 'Blocked-Social';
          final socialMediaData = await _getSocialMediaAddresses();
          
          // ابتدا IP rangeهای ثابت را اضافه می‌کنیم
          print('[DEBUG] enableSocialMediaFilter: Creating Address-List entries for platforms: $selectedPlatforms');
          int staticIPCount = await _createAddressListForStaticIPs(
            selectedPlatforms,
            addressListName,
          );
          print('[DEBUG] enableSocialMediaFilter: Static IPs added: $staticIPCount');
          
          // سپس دامنه‌های مهم را resolve می‌کنیم و IPها را اضافه می‌کنیم
          int resolvedCount = await _resolveAndAddDomainsToAddressList(
            selectedPlatforms,
            addressListName,
            socialMediaData,
          );
          print('[DEBUG] enableSocialMediaFilter: Resolved domains added: $resolvedCount');
          
          results['address_list_entries_added'] = staticIPCount + resolvedCount;
          results['resolved_domains'] = resolvedCount;
          
          // ایجاد Raw Rule برای Address-List (فقط Raw Rules، نه Filter Rules)
          // مهم: حتی اگر Address-List entries اضافه نشوند، Raw Rule را ایجاد کن
          // چون ممکن است entries از قبل وجود داشته باشند
          print('[DEBUG] enableSocialMediaFilter: Creating Raw Rule for Address-List...');
          print('[DEBUG] enableSocialMediaFilter: Device IP: $deviceIp, Platforms: $selectedPlatforms');
          
          // بررسی اینکه آیا Raw Rule از قبل وجود دارد
          final existingRawRules = await _client!.talk(['/ip/firewall/raw/print']);
          bool rawRuleExists = false;
          for (final rule in existingRawRules) {
            final srcAddr = rule['src-address']?.toString() ?? '';
            final dstList = rule['dst-address-list']?.toString() ?? '';
            final action = rule['action']?.toString() ?? '';
            final chain = rule['chain']?.toString() ?? '';
            if (srcAddr == deviceIp && 
                dstList == addressListName &&
                action == 'drop' &&
                chain == 'prerouting') {
              rawRuleExists = true;
              final ruleId = rule['.id']?.toString() ?? '';
              final ruleComment = rule['comment']?.toString() ?? '';
              print('[DEBUG] enableSocialMediaFilter: Raw Rule already exists: ID=$ruleId, comment="$ruleComment"');
              break;
            }
          }
          
          if (!rawRuleExists) {
            try {
              final rawRuleCount = await _createAddressListRawRule(
                deviceIp,
                deviceMac,
                addressListName,
                selectedPlatforms,
                deviceName,
              );
              results['address_list_rules_added'] = rawRuleCount;
              print('[DEBUG] enableSocialMediaFilter: Raw Rule created: $rawRuleCount');
              
              // ایجاد Filter Rule به عنوان backup (برای اطمینان بیشتر)
              try {
                final filterRuleCount = await _createAddressListFirewallRule(
                  deviceIp,
                  deviceMac,
                  addressListName,
                  deviceName,
                );
                print('[DEBUG] enableSocialMediaFilter: Filter Rule (backup) created: $filterRuleCount');
              } catch (e) {
                print('[DEBUG] enableSocialMediaFilter: Error creating Filter Rule (backup): $e');
                // ادامه می‌دهیم حتی اگر Filter Rule خطا داد
              }
              
              // بررسی مجدد بعد از ایجاد
              await Future.delayed(const Duration(milliseconds: 500));
              final verifyRawRules = await _client!.talk(['/ip/firewall/raw/print']);
              for (final rule in verifyRawRules) {
                final srcAddr = rule['src-address']?.toString() ?? '';
                final dstList = rule['dst-address-list']?.toString() ?? '';
                if (srcAddr == deviceIp && dstList == addressListName) {
                  final ruleId = rule['.id']?.toString() ?? '';
                  final ruleComment = rule['comment']?.toString() ?? '';
                  final action = rule['action']?.toString() ?? '';
                  final chain = rule['chain']?.toString() ?? '';
                  print('[DEBUG] enableSocialMediaFilter: Verified Raw Rule: ID=$ruleId, comment="$ruleComment", action="$action", chain="$chain"');
                }
              }
            } catch (e) {
              print('[DEBUG] enableSocialMediaFilter: Error creating Raw Rule: $e');
              results['errors'].add('خطا در ایجاد Raw Rule برای Address-List: $e');
            }
          } else {
            print('[DEBUG] enableSocialMediaFilter: Raw Rule already exists, checking Filter Rule...');
            // بررسی وجود Filter Rule
            final existingFilterRules = await _client!.talk(['/ip/firewall/filter/print']);
            bool filterRuleExists = false;
            for (final rule in existingFilterRules) {
              final srcAddr = rule['src-address']?.toString() ?? '';
              final dstList = rule['dst-address-list']?.toString() ?? '';
              if (srcAddr == deviceIp && dstList == addressListName) {
                filterRuleExists = true;
                break;
              }
            }
            if (!filterRuleExists) {
              try {
                final filterRuleCount = await _createAddressListFirewallRule(
                  deviceIp,
                  deviceMac,
                  addressListName,
                  deviceName,
                );
                print('[DEBUG] enableSocialMediaFilter: Filter Rule (backup) created: $filterRuleCount');
              } catch (e) {
                print('[DEBUG] enableSocialMediaFilter: Error creating Filter Rule (backup): $e');
              }
            }
            results['address_list_rules_added'] = 0;
          }
          
          // بررسی نهایی: آیا Address-List entries وجود دارند؟
          final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
          int finalCount = 0;
          for (final entry in allAddressList) {
            final list = entry['list']?.toString() ?? '';
            if (list == addressListName) {
              finalCount++;
            }
          }
          print('[DEBUG] enableSocialMediaFilter: Final Address-List entries count: $finalCount');
        } catch (e) {
          results['errors'].add('خطا در ایجاد Address-List: $e');
        }
      }

      // 4. اضافه کردن DNS Static Entries (redirect دامنه‌ها به 127.0.0.1)
      // این برای بلاک کردن DNS resolution دامنه‌های Facebook است
      try {
        print('[DEBUG] enableSocialMediaFilter: Adding DNS Static Entries for platforms: $selectedPlatforms');
        final socialMediaData = await _getSocialMediaAddresses();
        final dnsEntriesCount = await _addDNSStaticEntries(selectedPlatforms, socialMediaData);
        results['dns_entries_added'] = dnsEntriesCount;
        print('[DEBUG] enableSocialMediaFilter: DNS Static Entries added: $dnsEntriesCount');
      } catch (e) {
        print('[DEBUG] enableSocialMediaFilter: Error adding DNS Static Entries: $e');
        results['errors'].add('خطا در اضافه کردن DNS Static Entries: $e');
      }

      // 5. ایجاد TLS-SNI Firewall Rules (برای HTTPS blocking)
      // این rules برای بلاک کردن HTTPS traffic با استفاده از SNI (Server Name Indication)
      // مهم: فقط برای پلتفرم‌های انتخاب شده و محدود به src-address دستگاه هدف
      try {
        print('[DEBUG] enableSocialMediaFilter: Creating TLS-SNI rules for platforms: $selectedPlatforms');
        final tlsRuleCount = await _createTLSHostRulesForPlatforms(
          deviceIp,
          deviceMac,
          selectedPlatforms,
          deviceName,
        );
        results['firewall_rules_added'] = tlsRuleCount;
        results['tls_sni_rules_added'] = tlsRuleCount;
        print('[DEBUG] enableSocialMediaFilter: TLS-SNI rules created: $tlsRuleCount');
      } catch (e) {
        print('[DEBUG] enableSocialMediaFilter: Error creating TLS-SNI rules: $e');
        results['errors'].add('خطا در ایجاد TLS-SNI Rules: $e');
        results['firewall_rules_added'] = 0;
        results['tls_sni_rules_added'] = 0;
      }

      // 5. مسدودسازی QUIC/HTTP3 (UDP 443) برای دستگاه هدف
      // Facebook/Meta ممکن است از HTTP/3 (QUIC) استفاده کند
      try {
        print('[DEBUG] enableSocialMediaFilter: Creating QUIC blocking rule...');
        final allRules = await _client!.talk(['/ip/firewall/filter/print']);
        bool quicRuleExists = false;
        
        for (final rule in allRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final protocol = rule['protocol']?.toString() ?? '';
          final dstPort = rule['dst-port']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          
          if (srcAddress == deviceIp &&
              protocol == 'udp' &&
              dstPort == '443' &&
              comment.contains('Block QUIC')) {
            quicRuleExists = true;
            print('[DEBUG] enableSocialMediaFilter: QUIC blocking rule already exists');
            break;
          }
        }
        
        if (!quicRuleExists) {
          await _client!.talk([
            '/ip/firewall/filter/add',
            '=chain=forward',
            '=src-address=$deviceIp',
            '=protocol=udp',
            '=dst-port=443',
            '=action=drop',
            '=comment=SM-Filter:Platforms=${selectedPlatforms.join(",")}|Block QUIC for social media - Device: ${deviceName ?? deviceIp}',
          ]);
          print('[DEBUG] enableSocialMediaFilter: QUIC blocking rule created');
          results['quic_rules_added'] = 1;
        } else {
          results['quic_rules_added'] = 0;
        }
      } catch (e) {
        print('[DEBUG] enableSocialMediaFilter: Error creating QUIC blocking rule: $e');
        results['errors'].add('خطا در ایجاد QUIC blocking rule: $e');
        results['quic_rules_added'] = 0;
      }

      // اگر خطایی رخ داد اما حداقل یک عملیات موفق بود، success را true نگه دار
      if (results['errors'].length > 0 && 
          results['address_list_entries_added'] == 0 &&
          results['firewall_rules_added'] == 0 &&
          results['dns_bypass_rules_added'] == 0) {
        results['success'] = false;
      }

      return results;
    } catch (e) {
      results['success'] = false;
      results['errors'].add('خطای کلی: $e');
      return results;
    }
  }

  /// غیرفعال‌سازی فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  /// حذف کامل همه Filter Rules و Address List entries مربوط به این دستگاه
  Future<bool> disableSocialMediaFilter(String deviceIp) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    if (deviceIp.isEmpty) {
      throw Exception('آدرس IP دستگاه الزامی است');
    }

    try {
      // 1. حذف همه Firewall Filter Rules مربوط به این دستگاه
      // حذف همه rules که src-address آن‌ها این deviceIp است و یکی از شرایط زیر را دارند:
      // - comment شامل "Block social" است
      // - tls-host دارد (TLS-SNI rules)
      // - dst-address-list برابر "Blocked-Social" یا "Blocked-Social-IP" است
      // - comment شامل "Block public DNS" یا "Block DoT" یا "Block DoH" است
      try {
        final allRules = await _client!.talk(['/ip/firewall/filter/print']);
        for (final rule in allRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final tlsHost = rule['tls-host']?.toString() ?? '';
          final dstAddressList = rule['dst-address-list']?.toString() ?? '';
          final action = rule['action']?.toString() ?? '';
          
          // فقط rules مربوط به این deviceIp را بررسی کن
          if (srcAddress != deviceIp) continue;
          
          bool shouldRemove = false;
          
          // حذف همه rules که comment آن‌ها شامل "Block social" است (با هر فرمتی)
          if (comment.toLowerCase().contains('block social') || 
              comment.toLowerCase().contains('block-social')) {
            shouldRemove = true;
          }
          
          // حذف TLS-SNI rules (اگر tls-host دارد و action=drop است)
          if (tlsHost.isNotEmpty && action == 'drop') {
            // بررسی اینکه آیا tls-host مربوط به social media است
            final socialMediaDomains = [
              'telegram.org', 't.me', 'telegram.me',
              'facebook.com', 'fb.com', 'fbcdn.net',
              'instagram.com', 'cdninstagram.com',
              'tiktok.com', 'tiktokcdn.com',
              'whatsapp.com', 'whatsapp.net',
              'youtube.com', 'googlevideo.com',
            ];
            
            for (final domain in socialMediaDomains) {
              if (tlsHost.contains(domain)) {
                shouldRemove = true;
                break;
              }
            }
          }
          
          // حذف Address-List rules (اگر dst-address-list مربوط به social media است)
          if (dstAddressList == 'Blocked-Social' || 
              dstAddressList == 'Blocked-Social-IP' ||
              dstAddressList.contains('Blocked-Social')) {
            shouldRemove = true;
          }
          
          // حذف DNS bypass rules (Block public DNS, Block DoT, Block DoH)
          if (comment.contains('Block public DNS') || 
              comment.contains('Block DoT') ||
              comment.contains('Block DoH') ||
              comment.contains('Block DNS')) {
            shouldRemove = true;
          }
          
          // حذف HTTP rules برای social media (اگر dst-port=80 و comment شامل platform است)
          final dstPort = rule['dst-port']?.toString() ?? '';
          if (dstPort == '80' && action == 'drop') {
            final socialMediaKeywords = ['instagram', 'facebook', 'tiktok', 'telegram', 'whatsapp', 'youtube'];
            for (final keyword in socialMediaKeywords) {
              if (comment.toLowerCase().contains(keyword)) {
                shouldRemove = true;
                break;
              }
            }
          }
          
          // حذف همه rules که action=drop و src-address=deviceIp است و tls-host یا dst-address-list دارد
          // حتی اگر comment نداشته باشد (برای اطمینان از حذف کامل)
          if (!shouldRemove && action == 'drop') {
            // اگر tls-host دارد و مربوط به social media است
            if (tlsHost.isNotEmpty) {
              final socialMediaDomains = [
                'telegram', 'facebook', 'fb.com', 'instagram', 'tiktok', 
                'whatsapp', 'youtube', 'googlevideo', 'fbcdn', 'cdninstagram'
              ];
              for (final domain in socialMediaDomains) {
                if (tlsHost.toLowerCase().contains(domain)) {
                  shouldRemove = true;
                  break;
                }
              }
            }
            
            // اگر dst-address-list مربوط به social media است
            if (!shouldRemove && dstAddressList.isNotEmpty) {
              if (dstAddressList.contains('Blocked-Social') || 
                  dstAddressList.contains('Social')) {
                shouldRemove = true;
              }
            }
          }
          
          if (shouldRemove) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/filter/remove', '=.id=$ruleId']);
              } catch (e) {
                // continue - ممکن است قبلاً حذف شده باشد
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      // 2. حذف همه Raw Rules مربوط به این دستگاه
      try {
        final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (final rule in allRawRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          
          if (srcAddress == deviceIp && comment.contains('Block social')) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
              } catch (e) {
                // continue
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      // 3. حذف همه NAT Rules مربوط به این دستگاه (DNS redirect)
      try {
        final allNatRules = await _client!.talk(['/ip/firewall/nat/print']);
        for (final rule in allNatRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          
          if (srcAddress == deviceIp && comment.contains('Force DNS')) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/nat/remove', '=.id=$ruleId']);
              } catch (e) {
                // continue
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      // 4. حذف همه Address-List entries در "Blocked-Social" و "Blocked-Social-IP"
      // حذف کامل همه entries که comment آن‌ها شامل "Block" یا "Resolved" است
      try {
        final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
        for (final entry in allAddressList) {
          final list = entry['list']?.toString() ?? '';
          final comment = entry['comment']?.toString() ?? '';
          
          // حذف کامل همه entries در Blocked-Social یا Blocked-Social-IP
          if ((list == 'Blocked-Social' || list == 'Blocked-Social-IP') &&
              (comment.contains('Block') || 
               comment.contains('Resolved') ||
               comment.contains('static IP'))) {
            final entryId = entry['.id']?.toString();
            if (entryId != null) {
              try {
                await _client!.talk(['/ip/firewall/address-list/remove', '=.id=$entryId']);
              } catch (e) {
                // continue
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      return true;
    } catch (e) {
      throw Exception('خطا در غیرفعال‌سازی فیلتر: $e');
    }
  }

  /// بررسی وضعیت فیلترینگ شبکه‌های اجتماعی برای یک دستگاه
  Future<Map<String, dynamic>> getSocialMediaFilterStatus(String deviceIp) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    if (deviceIp.isEmpty) {
      throw Exception('آدرس IP دستگاه الزامی است');
    }

    try {
      // بررسی Raw Rules (روش اصلی برای فیلترینگ)
      final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
      bool hasRawRule = false;
      final List<String> rawRuleIds = [];
      
      // لاگ: تعداد Raw Rules
      print('[DEBUG] Total Raw Rules found: ${allRawRules.length}');
      
      // بررسی وضعیت هر پلتفرم جداگانه
      final platformStatus = <String, bool>{
        'telegram': false,
        'facebook': false,
        'instagram': false,
        'tiktok': false,
        'whatsapp': false,
        'youtube': false,
      };

      // بررسی Raw Rules
      int rawRuleIndex = 0;
      for (final rule in allRawRules) {
        rawRuleIndex++;
        final srcAddress = rule['src-address']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        final ruleId = rule['.id']?.toString() ?? '';
        
        // لاگ برای همه Raw Rules
        if (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') {
          print('[DEBUG] Raw Rule #$rawRuleIndex: src-address=$srcAddress, deviceIp=$deviceIp, match=${srcAddress == deviceIp}');
        }
        
        if (srcAddress == deviceIp) {
          // لاگ: Raw Rule مربوط به این device
          print('[DEBUG] Raw Rule #$rawRuleIndex for device $deviceIp:');
          print('[DEBUG]   Rule ID: $ruleId');
          print('[DEBUG]   Comment: $comment');
          print('[DEBUG]   Dst Address List: ${rule['dst-address-list']?.toString() ?? 'N/A'}');
          
          // بررسی Raw Rules با comment "Block social" یا "SM-Filter"
          // یا Raw Rules که به Blocked-Social اشاره می‌کنند (حتی اگر comment خالی باشد)
          final dstAddressList = rule['dst-address-list']?.toString() ?? '';
          final hasBlockedSocialAddressList = dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP';
          
          if (comment.contains('Block social') || comment.contains('SM-Filter') || hasBlockedSocialAddressList) {
            print('[DEBUG]   This Raw Rule matches "Block social" or "SM-Filter"');
            hasRawRule = true;
            rawRuleIds.add(ruleId);
            
            final commentLower = comment.toLowerCase();
            
            // اول: بررسی Platforms= یا Platforms- در comment (چند پلتفرم) - اولویت اول
            // مثال: SM-Filter:Platforms=telegram|Block social...
            bool foundViaTag = false;
            if (commentLower.contains('sm-filter:platforms=') || commentLower.contains('sm-filter:platforms-')) {
              // استفاده از regex برای استخراج لیست پلتفرم‌ها (قبل از |)
              // Pattern: SM-Filter:Platforms=telegram,facebook|...
              // استفاده از regex برای استخراج لیست پلتفرم‌ها (قبل از |)
              // Pattern: SM-Filter:Platforms=telegram,facebook|...
              // یا: SM-Filter:Platforms-telegram,facebook|...
              final platformsMatch = RegExp(r'sm-filter:platforms[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
              if (platformsMatch != null) {
                final platformsStr = platformsMatch.group(1)?.trim() ?? '';
                if (platformsStr.isNotEmpty) {
                  final platformsList = platformsStr.split(',').map((p) => p.trim().toLowerCase()).where((p) => p.isNotEmpty).toList();
                  for (final p in platformsList) {
                    if (platformStatus.containsKey(p)) {
                      platformStatus[p] = true;
                      foundViaTag = true;
                    }
                  }
                }
              }
              
              // اگر regex کار نکرد، بررسی ساده‌تر
              if (!foundViaTag) {
                // بررسی مستقیم: اگر comment شامل "Platforms=telegram" است
                for (final platform in platformStatus.keys) {
                  if (commentLower.contains('platforms=$platform') || 
                      commentLower.contains('platforms-$platform') ||
                      commentLower.contains('platform=$platform') ||
                      commentLower.contains('platform-$platform')) {
                    platformStatus[platform] = true;
                    foundViaTag = true;
                  }
                }
              }
            }
            
            // دوم: بررسی Platform= یا Platform- در comment (یک پلتفرم) - اولویت دوم
            // مثال: SM-Filter:Platform=telegram|Block social...
            if (!foundViaTag && (commentLower.contains('sm-filter:platform=') || commentLower.contains('sm-filter:platform-'))) {
              final platformMatch = RegExp(r'sm-filter:platform[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
              if (platformMatch != null) {
                final platformName = platformMatch.group(1)?.trim().toLowerCase() ?? '';
                if (platformName.isNotEmpty && platformStatus.containsKey(platformName)) {
                  platformStatus[platformName] = true;
                  foundViaTag = true;
                }
              }
            }
            
            // سوم: بررسی کلمات کلیدی در comment (fallback) - اولویت سوم
            // فقط اگر از Platforms= یا Platform= چیزی پیدا نشد
            if (!foundViaTag) {
              if (commentLower.contains('telegram')) platformStatus['telegram'] = true;
              if (commentLower.contains('facebook') || commentLower.contains('fb.com') || commentLower.contains('fb ')) platformStatus['facebook'] = true;
              if (commentLower.contains('instagram')) platformStatus['instagram'] = true;
              if (commentLower.contains('tiktok')) platformStatus['tiktok'] = true;
              if (commentLower.contains('whatsapp')) platformStatus['whatsapp'] = true;
              if (commentLower.contains('youtube') || commentLower.contains('googlevideo')) platformStatus['youtube'] = true;
            }
          }
          
          // بررسی Address-List در Raw Rules
          // مهم: این بررسی باید همیشه انجام شود، حتی اگر comment خالی باشد
          if (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') {
            print('[DEBUG]   Raw Rule has dst-address-list: $dstAddressList');
            // همیشه hasRawRule را true کن (حتی اگر comment خالی باشد)
            if (!hasRawRule) {
              hasRawRule = true;
            }
            if (!rawRuleIds.contains(ruleId)) {
              rawRuleIds.add(ruleId);
            }
            
            bool foundPlatformFromComment = false;
            
            // اگر comment دارد، از آن استفاده کن
            if (comment.isNotEmpty) {
              print('[DEBUG]   Comment for Address-List rule: $comment');
              final commentLower = comment.toLowerCase();
              
              bool foundViaTagInAddressList = false;
              
              // اول: بررسی Platforms= یا Platforms- در comment (چند پلتفرم)
              if (commentLower.contains('sm-filter:platforms=') || commentLower.contains('sm-filter:platforms-')) {
                final platformsMatch = RegExp(r'sm-filter:platforms[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
                if (platformsMatch != null) {
                  final platformsStr = platformsMatch.group(1)?.trim() ?? '';
                  if (platformsStr.isNotEmpty) {
                    final platformsList = platformsStr.split(',').map((p) => p.trim().toLowerCase()).where((p) => p.isNotEmpty).toList();
                    print('[DEBUG]   Found platforms from Raw Rule comment: $platformsList');
                    for (final p in platformsList) {
                      if (platformStatus.containsKey(p)) {
                        platformStatus[p] = true;
                        foundViaTagInAddressList = true;
                        foundPlatformFromComment = true;
                      }
                    }
                  }
                }
              }
              
              // دوم: بررسی Platform= یا Platform- در comment (یک پلتفرم)
              if (!foundViaTagInAddressList && (commentLower.contains('sm-filter:platform=') || commentLower.contains('sm-filter:platform-'))) {
                final platformMatch = RegExp(r'sm-filter:platform[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
                if (platformMatch != null) {
                  final platformName = platformMatch.group(1)?.trim().toLowerCase() ?? '';
                  if (platformName.isNotEmpty && platformStatus.containsKey(platformName)) {
                    platformStatus[platformName] = true;
                    foundViaTagInAddressList = true;
                    foundPlatformFromComment = true;
                    print('[DEBUG]   Found platform from Raw Rule comment: $platformName');
                  }
                }
              }
              
              // سوم: بررسی کلمات کلیدی (fallback)
              if (!foundViaTagInAddressList) {
                if (commentLower.contains('telegram')) {
                  platformStatus['telegram'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "telegram" keyword in comment');
                }
                if (commentLower.contains('facebook') || commentLower.contains('fb')) {
                  platformStatus['facebook'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "facebook" keyword in comment');
                }
                if (commentLower.contains('instagram')) {
                  platformStatus['instagram'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "instagram" keyword in comment');
                }
                if (commentLower.contains('tiktok')) {
                  platformStatus['tiktok'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "tiktok" keyword in comment');
                }
                if (commentLower.contains('whatsapp')) {
                  platformStatus['whatsapp'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "whatsapp" keyword in comment');
                }
                if (commentLower.contains('youtube')) {
                  platformStatus['youtube'] = true;
                  foundPlatformFromComment = true;
                  print('[DEBUG]   Found "youtube" keyword in comment');
                }
              }
            } else {
              print('[DEBUG]   Raw Rule comment is empty, will use IP-based detection');
            }
            
            // اگر از comment چیزی پیدا نشد، از IP addresses در Address-List استفاده کن
            if (!foundPlatformFromComment) {
              print('[DEBUG]   No platform found from comment, checking Address-List IPs...');
              // این بخش بعداً در حلقه Address-List entries انجام می‌شود
            }
          }
        }
      }

      // بررسی Filter Rules (برای سازگاری با rules قدیمی)
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      bool hasFirewallRule = false;
      bool hasDNSBypassBlock = false;
      final List<String> firewallRuleIds = [];
      final List<String> dnsBypassRuleIds = [];

      for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final tlsHost = rule['tls-host']?.toString() ?? '';
        final ruleId = rule['.id']?.toString() ?? '';
        
        if (srcAddress == deviceIp) {
          // بررسی rules با comment "Block social"
          if (comment.contains('Block social')) {
            hasFirewallRule = true;
            firewallRuleIds.add(ruleId);
            
            // بررسی اینکه کدام پلتفرم فیلتر شده
            final commentLower = comment.toLowerCase();
            if (commentLower.contains('telegram')) platformStatus['telegram'] = true;
            if (commentLower.contains('facebook') || commentLower.contains('fb.com')) platformStatus['facebook'] = true;
            if (commentLower.contains('instagram')) platformStatus['instagram'] = true;
            if (commentLower.contains('tiktok')) platformStatus['tiktok'] = true;
            if (commentLower.contains('whatsapp')) platformStatus['whatsapp'] = true;
            if (commentLower.contains('youtube') || commentLower.contains('googlevideo')) platformStatus['youtube'] = true;
          }
          
          // بررسی Address-List rules (حتی اگر comment متفاوت باشد)
          final dstAddressList = rule['dst-address-list']?.toString() ?? '';
          if (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') {
            hasFirewallRule = true;
            // اگر comment دارد، از آن استفاده کن
            if (comment.isNotEmpty) {
              final commentLower = comment.toLowerCase();
              if (commentLower.contains('telegram')) platformStatus['telegram'] = true;
              if (commentLower.contains('facebook') || commentLower.contains('fb')) platformStatus['facebook'] = true;
              if (commentLower.contains('instagram')) platformStatus['instagram'] = true;
              if (commentLower.contains('tiktok')) platformStatus['tiktok'] = true;
              if (commentLower.contains('whatsapp')) platformStatus['whatsapp'] = true;
              if (commentLower.contains('youtube')) platformStatus['youtube'] = true;
            }
          }
          
          // بررسی TLS-SNI rules (حتی اگر comment نداشته باشد)
          if (tlsHost.isNotEmpty) {
            final tlsHostLower = tlsHost.toLowerCase();
            if (tlsHostLower.contains('telegram.org') || tlsHostLower.contains('t.me') || tlsHostLower.contains('telegram.me')) {
              platformStatus['telegram'] = true;
            }
          }
          
          if (comment.contains('Block DoH') || comment.contains('Block DoT') || comment.contains('Block DNS')) {
            hasDNSBypassBlock = true;
            dnsBypassRuleIds.add(ruleId);
          }
        }
      }

      // بررسی Address-List entries مربوط به این دستگاه
      // استخراج پلتفرم‌ها از comment Address-List entries
      // اگر Raw Rule برای این device وجود دارد که به Blocked-Social اشاره می‌کند،
      // باید همه پلتفرم‌های موجود در Address-List را فعال کنیم
      final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
      print('[DEBUG] Total Address-List entries found: ${allAddressList.length}');
      
      int addressListCount = 0;
      final Set<String> foundPlatforms = <String>{};
      
      // اگر Raw Rule برای این device وجود دارد که به Blocked-Social اشاره می‌کند
      bool hasRawRuleForAddressList = false;
      print('[DEBUG] Checking all Raw Rules for device $deviceIp...');
      print('[DEBUG] Total Raw Rules to check: ${allRawRules.length}');
      
      // لاگ برای همه Raw Rules (برای debug)
      for (int i = 0; i < allRawRules.length && i < 10; i++) {
        final rawRule = allRawRules[i];
        final srcAddress = rawRule['src-address']?.toString() ?? '';
        final dstAddressList = rawRule['dst-address-list']?.toString() ?? '';
        final action = rawRule['action']?.toString() ?? '';
        final chain = rawRule['chain']?.toString() ?? '';
        final ruleId = rawRule['.id']?.toString() ?? '';
        print('[DEBUG] Raw Rule #${i + 1} ID=$ruleId: src-address="$srcAddress", dst-address-list="$dstAddressList", action="$action", chain="$chain"');
      }
      
      for (final rawRule in allRawRules) {
        final srcAddress = rawRule['src-address']?.toString() ?? '';
        final dstAddressList = rawRule['dst-address-list']?.toString() ?? '';
        final action = rawRule['action']?.toString() ?? '';
        final chain = rawRule['chain']?.toString() ?? '';
        final ruleId = rawRule['.id']?.toString() ?? '';
        
        // لاگ برای همه Raw Rules که به Blocked-Social اشاره می‌کنند
        if (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') {
          print('[DEBUG] Raw Rule ID=$ruleId: src-address="$srcAddress", deviceIp="$deviceIp", match=${srcAddress == deviceIp}, action="$action", chain="$chain"');
        }
        
        // بررسی دقیق‌تر: باید action=drop و chain=prerouting باشد
        if (srcAddress == deviceIp && 
            (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') &&
            action == 'drop' &&
            chain == 'prerouting') {
          hasRawRuleForAddressList = true;
          print('[DEBUG] Found Raw Rule for device $deviceIp pointing to Address-List: $dstAddressList');
          break;
        }
      }
      
      if (!hasRawRuleForAddressList) {
        print('[DEBUG] No Raw Rule found for device $deviceIp pointing to Blocked-Social');
      }
      
      // بررسی اینکه آیا Firewall Rule به Blocked-Social اشاره می‌کند
      bool hasFirewallRuleForAddressList = false;
      for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        if (srcAddress == deviceIp && 
            (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP')) {
          hasFirewallRuleForAddressList = true;
          print('[DEBUG] Found Firewall Rule for device $deviceIp pointing to Address-List: $dstAddressList');
          break;
        }
      }
      
      // اگر Raw Rule یا Firewall Rule برای Address-List وجود دارد، همه Address-List entries را بررسی کن
      // یا اگر Address-List entries وجود دارند، آن‌ها را بررسی کن (fallback)
      if (hasRawRuleForAddressList || hasFirewallRuleForAddressList || allAddressList.isNotEmpty) {
        print('[DEBUG] Checking Address-List entries for platforms...');
        print('[DEBUG] Total Address-List entries to check: ${allAddressList.length}');
        int entryIndex = 0;
        int blockedSocialCount = 0;
        for (final entry in allAddressList) {
          final list = entry['list']?.toString() ?? '';
          final comment = entry['comment']?.toString() ?? '';
          final address = entry['address']?.toString() ?? '';
          
          // لاگ برای همه entries (برای debug)
          if (entryIndex < 10) { // فقط 10 تا اول را لاگ کن
            print('[DEBUG]   Address-List Entry #${entryIndex + 1}: list="$list", address="$address", comment="$comment"');
          }
          
          if (list == 'Blocked-Social' || list == 'Blocked-Social-IP') {
            blockedSocialCount++;
            print('[DEBUG]   Found Blocked-Social entry #$blockedSocialCount: address="$address", comment="$comment"');
            entryIndex++;
            addressListCount++;
            print('[DEBUG]   Address-List Entry #$entryIndex:');
            print('[DEBUG]     Address: $address');
            print('[DEBUG]     List: $list');
            print('[DEBUG]     Comment: $comment');
            
            if (comment.isNotEmpty) {
              final commentLower = comment.toLowerCase();
              
              // بررسی Platforms= یا Platforms- در comment
              if (commentLower.contains('sm-filter:platforms=') || commentLower.contains('sm-filter:platforms-')) {
                print('[DEBUG]     Found "sm-filter:platforms=" or "sm-filter:platforms-" in comment');
                final platformsMatch = RegExp(r'sm-filter:platforms[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
                if (platformsMatch != null) {
                  final platformsStr = platformsMatch.group(1)?.trim() ?? '';
                  print('[DEBUG]     Extracted platforms string: "$platformsStr"');
                  if (platformsStr.isNotEmpty) {
                    final platformsList = platformsStr.split(',').map((p) => p.trim().toLowerCase()).where((p) => p.isNotEmpty).toList();
                    print('[DEBUG]     Parsed platforms list: $platformsList');
                    for (final p in platformsList) {
                      if (platformStatus.containsKey(p)) {
                        foundPlatforms.add(p);
                        print('[DEBUG]     Platform "$p" added to foundPlatforms');
                      }
                    }
                  }
                }
              }
              
              // بررسی Platform= یا Platform- در comment
              if (commentLower.contains('sm-filter:platform=') || commentLower.contains('sm-filter:platform-')) {
                print('[DEBUG]     Found "sm-filter:platform=" or "sm-filter:platform-" in comment');
                final platformMatch = RegExp(r'sm-filter:platform[=-]([^|]+)', caseSensitive: false).firstMatch(comment);
                if (platformMatch != null) {
                  final platformName = platformMatch.group(1)?.trim().toLowerCase() ?? '';
                  print('[DEBUG]     Extracted platform name: "$platformName"');
                  if (platformName.isNotEmpty && platformStatus.containsKey(platformName)) {
                    foundPlatforms.add(platformName);
                    print('[DEBUG]     Platform "$platformName" added to foundPlatforms');
                  }
                }
              }
              
              // بررسی کلمات کلیدی در comment (fallback)
              if (commentLower.contains('block telegram') || commentLower.contains('telegram')) {
                foundPlatforms.add('telegram');
                print('[DEBUG]     Found "telegram" keyword, added to foundPlatforms');
              }
              if (commentLower.contains('block facebook') || commentLower.contains('facebook') || commentLower.contains('fb ')) {
                foundPlatforms.add('facebook');
                print('[DEBUG]     Found "facebook" keyword, added to foundPlatforms');
              }
              if (commentLower.contains('block instagram') || commentLower.contains('instagram')) {
                foundPlatforms.add('instagram');
                print('[DEBUG]     Found "instagram" keyword, added to foundPlatforms');
              }
              if (commentLower.contains('block tiktok') || commentLower.contains('tiktok')) {
                foundPlatforms.add('tiktok');
                print('[DEBUG]     Found "tiktok" keyword, added to foundPlatforms');
              }
              if (commentLower.contains('block whatsapp') || commentLower.contains('whatsapp')) {
                foundPlatforms.add('whatsapp');
                print('[DEBUG]     Found "whatsapp" keyword, added to foundPlatforms');
              }
              if (commentLower.contains('block youtube') || commentLower.contains('youtube')) {
                foundPlatforms.add('youtube');
                print('[DEBUG]     Found "youtube" keyword, added to foundPlatforms');
              }
            } else {
              print('[DEBUG]     No comment in this entry, will use IP-based detection');
            }
          }
        }
        
        // اگر از comment چیزی پیدا نشد، از IP addresses استفاده کن
        // مهم: IP-based detection فقط به عنوان fallback استفاده می‌شود
        // و برای IP های مشترک (مثل 31.13.x.x که هم Facebook و هم WhatsApp است)،
        // باید از comment استفاده کنیم - اگر comment خالی است، از IP استفاده نمی‌کنیم
        if (foundPlatforms.isEmpty && addressListCount > 0) {
          print('[DEBUG] No platforms found from comments, checking if we can use IP-based detection...');
          
          // بررسی اینکه آیا همه entries comment خالی دارند
          bool allCommentsEmpty = true;
          for (final entry in allAddressList) {
            final list = entry['list']?.toString() ?? '';
            final comment = entry['comment']?.toString() ?? '';
            if ((list == 'Blocked-Social' || list == 'Blocked-Social-IP') && comment.isNotEmpty) {
              allCommentsEmpty = false;
              break;
            }
          }
          
          // فقط اگر همه comments خالی هستند، از IP-based detection استفاده کن
          // اما برای IP های مشترک (31.13.x.x)، از IP-based detection استفاده نکن
          if (allCommentsEmpty) {
            print('[DEBUG] All comments are empty, using IP-based detection (with caution for shared IPs)...');
            // بررسی IP addresses برای شناسایی پلتفرم
            for (final entry in allAddressList) {
              final list = entry['list']?.toString() ?? '';
              final address = entry['address']?.toString() ?? '';
              
              if (list == 'Blocked-Social' || list == 'Blocked-Social-IP') {
                // شناسایی پلتفرم از IP address
                // تلگرام: 149.154.x.x و 91.108.x.x (منحصر به فرد)
                if ((address.startsWith('149.154.') || address.startsWith('91.108.')) && !foundPlatforms.contains('telegram')) {
                  foundPlatforms.add('telegram');
                  print('[DEBUG]   Detected telegram from IP: $address');
                }
                // فیسبوک: IP ranges منحصر به فرد (بدون 31.13.x.x که مشترک است)
                else if ((address.startsWith('31.13.24.') || address.startsWith('31.13.64.') ||
                         address.startsWith('45.64.40.') || address.startsWith('57.144.16.') ||
                         address.startsWith('66.220.') || address.startsWith('69.63.') || 
                         address.startsWith('69.171.') || address.startsWith('74.119.76.') ||
                         address.startsWith('102.132.96.') || address.startsWith('103.4.') ||
                         address.startsWith('129.134.') || address.startsWith('147.75.208.') ||
                         address.startsWith('157.240.') || address.startsWith('173.252.') ||
                         address.startsWith('179.60.') || address.startsWith('185.60.') ||
                         address.startsWith('185.89.') || address.startsWith('204.15.')) && 
                         !foundPlatforms.contains('facebook')) {
                  foundPlatforms.add('facebook');
                  print('[DEBUG]   Detected facebook from IP: $address');
                }
                // اینستاگرام: IP ranges منحصر به فرد
                else if ((address.startsWith('54.230.') || address.startsWith('54.239.')) && !foundPlatforms.contains('instagram')) {
                  foundPlatforms.add('instagram');
                  print('[DEBUG]   Detected instagram from IP: $address');
                }
                // تیک‌تاک: 13.107.42.x, 20.42.64.x, 103.27.148.x (منحصر به فرد)
                else if ((address.startsWith('13.107.42.') || address.startsWith('20.42.64.') ||
                         address.startsWith('103.27.148.')) && !foundPlatforms.contains('tiktok')) {
                  foundPlatforms.add('tiktok');
                  print('[DEBUG]   Detected tiktok from IP: $address');
                }
                // یوتیوب: 172.217.x.x, 142.250.x.x, 74.125.x.x, 216.58.x.x (منحصر به فرد)
                else if ((address.startsWith('172.217.') || address.startsWith('142.250.') ||
                         address.startsWith('74.125.') || address.startsWith('216.58.')) && !foundPlatforms.contains('youtube')) {
                  foundPlatforms.add('youtube');
                  print('[DEBUG]   Detected youtube from IP: $address');
                }
                // واتساپ و فیسبوک: 31.13.x.x (مشترک) - از IP-based detection استفاده نکن
                // این IP ها باید از comment شناسایی شوند
                // اگر comment خالی است، نمی‌توانیم تشخیص دهیم که کدام پلتفرم است
              }
            }
          } else {
            print('[DEBUG] Some entries have comments, skipping IP-based detection to avoid false positives');
          }
        }
        
        print('[DEBUG] Total Address-List entries in Blocked-Social: $addressListCount');
        print('[DEBUG] Found platforms from Address-List: $foundPlatforms');
        
        // فعال کردن همه پلتفرم‌های پیدا شده
        for (final platform in foundPlatforms) {
          platformStatus[platform] = true;
          print('[DEBUG] Platform "$platform" marked as filtered in platformStatus');
        }
      } else {
        print('[DEBUG] Skipping Address-List check (no Raw Rule for Address-List)');
      }

      // بررسی DNS Static Entries
      final allDNSStatic = await _client!.talk(['/ip/dns/static/print']);
      int dnsStaticCount = 0;
      for (final entry in allDNSStatic) {
        final comment = entry['comment']?.toString() ?? '';
        if (comment.contains('Block') && entry['address']?.toString() == '127.0.0.1') {
          dnsStaticCount++;
        }
      }

      // وضعیت فعال است اگر Raw Rule یا Filter Rule یا Address-List وجود داشته باشد
      // همچنین اگر حداقل یک پلتفرم فیلتر شده باشد
      final hasAnyPlatformFiltered = platformStatus.values.any((status) => status == true);
      final isActive = hasRawRule || hasFirewallRule || hasDNSBypassBlock || addressListCount > 0 || hasAnyPlatformFiltered;
      
      // لاگ نهایی
      print('[DEBUG] ========== Final Status Summary ==========');
      print('[DEBUG] Device IP: $deviceIp');
      print('[DEBUG] Has Raw Rule: $hasRawRule');
      print('[DEBUG] Has Firewall Rule: $hasFirewallRule');
      print('[DEBUG] Address List Count: $addressListCount');
      print('[DEBUG] Has Any Platform Filtered: $hasAnyPlatformFiltered');
      print('[DEBUG] Platform Status: $platformStatus');
      print('[DEBUG] Is Active: $isActive');
      print('[DEBUG] ==================================================');
      
      return {
        'is_active': isActive,
        'has_raw_rule': hasRawRule,
        'has_firewall_rule': hasFirewallRule,
        'has_dns_bypass_block': hasDNSBypassBlock,
        'raw_rule_ids': rawRuleIds,
        'firewall_rule_ids': firewallRuleIds,
        'dns_bypass_rule_ids': dnsBypassRuleIds,
        'address_list_count': addressListCount,
        'dns_static_count': dnsStaticCount,
        'platforms': platformStatus,
      };
    } catch (e) {
      throw Exception('خطا در بررسی وضعیت فیلتر: $e');
    }
  }

  /// فیلتر/رفع فیلتر یک پلتفرم خاص برای یک دستگاه
  Future<Map<String, dynamic>> togglePlatformFilter(
    String deviceIp,
    String platform, {
    String? deviceMac,
    String? deviceName,
    bool enable = true,
  }) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    if (deviceIp.isEmpty) {
      throw Exception('آدرس IP دستگاه الزامی است');
    }

    final platformLower = platform.toLowerCase();
    final validPlatforms = ['telegram', 'facebook', 'instagram', 'tiktok', 'whatsapp', 'youtube'];
    
    if (!validPlatforms.contains(platformLower)) {
      throw Exception('پلتفرم نامعتبر: $platform');
    }

    try {
      if (enable) {
        // قبل از فعال‌سازی: پاکسازی rules قدیمی این پلتفرم
        final cleanedCount = await _cleanupOldPlatformRules(deviceIp, platformLower);
        
        // فعال‌سازی فیلتر برای این پلتفرم
        final result = await enableSocialMediaFilter(
          deviceIp,
          deviceMac: deviceMac,
          deviceName: deviceName,
          platforms: [platformLower],
        );
        return {
          'success': result['success'] == true,
          'platform': platformLower,
          'action': 'enabled',
          'old_rules_cleaned': cleanedCount,
          'result': result,
        };
      } else {
        // غیرفعال‌سازی فیلتر برای این پلتفرم
        final success = await disablePlatformFilter(deviceIp, platformLower);
        return {
          'success': success,
          'platform': platformLower,
          'action': 'disabled',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'platform': platformLower,
        'error': e.toString(),
      };
    }
  }

  /// بررسی اینکه آیا comment شامل tag مربوط به پلتفرم است
  /// پشتیبانی از format های مختلف: Platform=, Platform-, Platforms=, Platforms-
  bool _hasPlatformTag(String comment, String platform) {
    if (comment.isEmpty) return false;
    
    final platformLower = platform.toLowerCase();
    final commentLower = comment.toLowerCase();
    final commentUpper = comment.toUpperCase();
    final platformUpper = platformLower.toUpperCase();
    
    // بررسی همه format های ممکن tag برای یک پلتفرم
    // Format 1: SM-Filter:Platform=facebook (با equals)
    if (commentLower.contains('sm-filter:platform=$platformLower') ||
        commentUpper.contains('SM-FILTER:PLATFORM=$platformUpper') ||
        comment.contains('SM-Filter:Platform=$platformLower') ||
        comment.contains('SM-Filter:Platform=$platformLower|') ||
        comment.contains('SM-Filter:Platform=$platformLower,')) {
      return true;
    }
    
    // Format 2: SM-Filter:Platform-facebook (با dash - MikroTik ممکن است = را به - تبدیل کند)
    if (commentLower.contains('sm-filter:platform-$platformLower') ||
        commentUpper.contains('SM-FILTER:PLATFORM-$platformUpper') ||
        comment.contains('SM-Filter:Platform-$platformLower') ||
        comment.contains('SM-Filter:Platform-$platformLower|') ||
        comment.contains('SM-Filter:Platform-$platformLower,')) {
      return true;
    }
    
    // بررسی Platforms= (چند پلتفرم) - با equals
    if (commentLower.contains('sm-filter:platforms=')) {
      final platformsMatch = RegExp(r'sm-filter:platforms=([^|]+)', caseSensitive: false).firstMatch(commentLower);
      if (platformsMatch != null) {
        final platformsList = platformsMatch.group(1)?.split(',');
        if (platformsList != null) {
          for (final p in platformsList) {
            if (p.trim() == platformLower) {
              return true;
            }
          }
        }
      }
    }
    
    // بررسی Platforms- (چند پلتفرم) - با dash
    if (commentLower.contains('sm-filter:platforms-')) {
      // استخراج لیست پلتفرم‌ها از بعد از dash
      final platformsMatch = RegExp(r'sm-filter:platforms-([^|]+)', caseSensitive: false).firstMatch(commentLower);
      if (platformsMatch != null) {
        final platformsList = platformsMatch.group(1)?.split(',');
        if (platformsList != null) {
          for (final p in platformsList) {
            if (p.trim() == platformLower) {
              return true;
            }
          }
        }
      }
    }
    
    return false;
  }

  /// پاکسازی rules قدیمی یک پلتفرم قبل از ایجاد rules جدید
  /// این متد rules قدیمی را حذف می‌کند تا از ایجاد rules تکراری جلوگیری شود
  /// شامل: Filter Rules, Raw Rules, TLS-SNI Rules
  Future<int> _cleanupOldPlatformRules(String deviceIp, String platform) async {
    if (_client == null || !isConnected) {
      return 0;
    }

    final platformLower = platform.toLowerCase();
    int removedCount = 0;

    try {
      // 1. حذف Filter Rules قدیمی (شامل TLS-SNI rules)
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final tlsHost = rule['tls-host']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        
        if (srcAddress != deviceIp) continue;
        
        bool shouldRemove = false;
        
        // بررسی tag در comment (پشتیبانی از format های = و -)
        if (comment.isNotEmpty) {
          final commentLower = comment.toLowerCase();
          
          if (_hasPlatformTag(comment, platformLower)) {
            shouldRemove = true;
          } else {
            // بررسی format Platform-facebook (با dash) که MikroTik ممکن است نمایش دهد
            if ((commentLower.contains('sm-filter:platform-$platformLower') ||
                 commentLower.contains('sm-filter:platforms-$platformLower')) &&
                commentLower.contains('block social')) {
              shouldRemove = true;
            }
          }
          
          // بررسی ساده و قاطع: اگر comment شامل کلمات کلیدی پلتفرم باشد (بدون توجه به format یا tag)
          // این برای اطمینان از حذف همه rules مربوط به پلتفرم
          if (!shouldRemove) {
            final platformKeywords = {
              'telegram': ['telegram'],
              'facebook': ['facebook', 'fb.com', 'fbcdn', 'fb '],
              'instagram': ['instagram', 'cdninstagram'],
              'tiktok': ['tiktok'],
              'whatsapp': ['whatsapp', 'wa.me'],
              'youtube': ['youtube', 'googlevideo'],
            };
            
            final keywords = platformKeywords[platformLower] ?? [];
            for (final keyword in keywords) {
              if (commentLower.contains(keyword)) {
                shouldRemove = true;
                break;
              }
            }
          }
        }
        
        // بررسی TLS-SNI rules که ممکن است tag نداشته باشند
        if (!shouldRemove && tlsHost.isNotEmpty && comment.isNotEmpty) {
          final commentLower = comment.toLowerCase();
          // بررسی کلمات کلیدی پلتفرم در comment
          final platformKeywords = {
            'telegram': ['telegram'],
            'facebook': ['facebook', 'fb.com', 'fbcdn', 'fb '],
            'instagram': ['instagram', 'cdninstagram'],
            'tiktok': ['tiktok'],
            'whatsapp': ['whatsapp', 'wa.me'],
            'youtube': ['youtube', 'googlevideo'],
          };
          
          final keywords = platformKeywords[platformLower] ?? [];
          for (final keyword in keywords) {
            if (commentLower.contains(keyword)) {
              shouldRemove = true;
              break;
            }
          }
        }
        
        // بررسی Address-List rules
        if (!shouldRemove && (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP')) {
          if (comment.isNotEmpty && _hasPlatformTag(comment, platformLower)) {
            shouldRemove = true;
          }
        }
        
        if (shouldRemove) {
          final ruleId = rule['.id']?.toString();
          if (ruleId != null) {
            try {
              await _client!.talk(['/ip/firewall/filter/remove', '=.id=$ruleId']);
              removedCount++;
            } catch (e) {
              // continue
            }
          }
        }
      }

      // 2. حذف Raw Rules قدیمی
      final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
      for (final rule in allRawRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        
        if (srcAddress == deviceIp && comment.isNotEmpty) {
          if (_hasPlatformTag(comment, platformLower)) {
            final ruleId = rule['.id']?.toString();
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
                removedCount++;
              } catch (e) {
                // continue
              }
            }
          }
        }
      }
    } catch (e) {
      // continue
    }

    return removedCount;
  }

  /// غیرفعال‌سازی فیلتر یک پلتفرم خاص
  /// حذف کامل همه Filter Rules و Address-List entries مربوط به این پلتفرم
  Future<bool> disablePlatformFilter(String deviceIp, String platform) async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    if (deviceIp.isEmpty) {
      throw Exception('آدرس IP دستگاه الزامی است');
    }

    final platformLower = platform.toLowerCase();
    int removedCount = 0;

    // لیست دامنه‌ها و کلمات کلیدی برای هر پلتفرم
    final platformData = {
      'telegram': {
        'domains': ['telegram.org', 't.me', 'telegram.me', 'telesco.pe', 'tg.dev', 'core.telegram.org'],
        'keywords': ['telegram'],
      },
      'facebook': {
        'domains': [
          'facebook.com', 'www.facebook.com', 'fb.com', 'www.fb.com', 'm.facebook.com',
          'login.facebook.com', 'graph.facebook.com', 'connect.facebook.net',
          'fbcdn.net', 'static.ak.fbcdn.net', 'scontent.xx.fbcdn.net',
          'apps.facebook.com', 'upload.facebook.com', 'web.facebook.com',
          'web-fallback.facebook.com', 'edge-chat.facebook.com', 'api.facebook.com',
          'facebook.net', 'fbstatic.com', 'fbsbx.com', 'fbpigeon.com', 'facebook-hardware.com',
        ],
        'keywords': ['facebook', 'fb.com', 'fbcdn'],
      },
    };

    final platformInfo = platformData[platformLower];
    if (platformInfo == null) {
      throw Exception('پلتفرم نامعتبر: $platform');
    }

    final domains = platformInfo['domains'] as List<String>;
    final keywords = platformInfo['keywords'] as List<String>;

    try {
      // 1. حذف همه Firewall Filter Rules مربوط به این پلتفرم
      final allRules = await _client!.talk(['/ip/firewall/filter/print']);
      for (final rule in allRules) {
        final srcAddress = rule['src-address']?.toString() ?? '';
        final comment = rule['comment']?.toString() ?? '';
        final tlsHost = rule['tls-host']?.toString() ?? '';
        final dstAddressList = rule['dst-address-list']?.toString() ?? '';
        
        if (srcAddress != deviceIp) continue;
        
        bool shouldRemove = false;
        final commentLower = comment.toLowerCase();
        final tlsHostLower = tlsHost.toLowerCase();
        
        // روش اصلی: بررسی tag "SM-Filter:Platform=" یا "SM-Filter:Platform-" در comment
        if (comment.isNotEmpty) {
          // بررسی tag برای این پلتفرم (پشتیبانی از format های = و -)
          if (_hasPlatformTag(comment, platformLower)) {
            shouldRemove = true;
          }
          
          // بررسی جامع: اگر comment شامل "SM-Filter" و نام پلتفرم است
          // این برای rules قدیمی که ممکن است format متفاوتی داشته باشند
          if (!shouldRemove && (comment.contains('SM-Filter') || commentLower.contains('sm-filter'))) {
            // بررسی format Platform-facebook (با dash)
            if (commentLower.contains('platform-$platformLower') || 
                commentLower.contains('platforms-$platformLower')) {
              shouldRemove = true;
            } else {
              // بررسی کلمات کلیدی
              for (final keyword in keywords) {
                if (commentLower.contains(keyword) && commentLower.contains('block social')) {
                  shouldRemove = true;
                  break;
                }
              }
            }
          }
        }
        
        // روش ساده و قاطع: اگر comment شامل کلمات کلیدی پلتفرم باشد (بدون توجه به format یا tag)
        // این برای اطمینان از حذف همه rules مربوط به پلتفرم
        if (!shouldRemove && comment.isNotEmpty) {
          for (final keyword in keywords) {
            if (commentLower.contains(keyword)) {
              shouldRemove = true;
              break;
            }
          }
        }
        
        // بررسی TLS-SNI rules - اگر tls-host شامل دامنه‌های پلتفرم باشد
        if (!shouldRemove && tlsHost.isNotEmpty) {
          for (final domain in domains) {
            if (tlsHostLower.contains(domain)) {
              shouldRemove = true;
              break;
            }
          }
        }
        
        // بررسی Address-List rules - اگر dst-address-list مربوط به social media است
        // و comment شامل tag پلتفرم است
        if (!shouldRemove && (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP')) {
          if (comment.isNotEmpty) {
            if (_hasPlatformTag(comment, platformLower)) {
              shouldRemove = true;
            } else {
              // Fallback: بررسی کلمات کلیدی
              for (final keyword in keywords) {
                if (commentLower.contains(keyword)) {
                  shouldRemove = true;
                  break;
                }
              }
            }
          }
        }
        
        if (shouldRemove) {
          final ruleId = rule['.id']?.toString();
          if (ruleId != null) {
            try {
              await _client!.talk(['/ip/firewall/filter/remove', '=.id=$ruleId']);
              removedCount++;
            } catch (e) {
              // continue - ممکن است قبلاً حذف شده باشد
            }
          }
        }
      }

      // 2. حذف Raw Rules مربوط به این پلتفرم
      // الگو: مشابه unbanClient - حذف بر اساس IP و dst-address-list (حتی اگر comment خالی باشد)
      try {
        final allRawRules = await _client!.talk(['/ip/firewall/raw/print']);
        for (final rule in allRawRules) {
          final srcAddress = rule['src-address']?.toString() ?? '';
          final comment = rule['comment']?.toString() ?? '';
          final dstAddressList = rule['dst-address-list']?.toString() ?? '';
          final action = rule['action']?.toString() ?? '';
          final chain = rule['chain']?.toString() ?? '';
          
          // بررسی تطابق IP و dst-address-list (مشابه unbanClient)
          if (srcAddress == deviceIp && 
              (dstAddressList == 'Blocked-Social' || dstAddressList == 'Blocked-Social-IP') &&
              action == 'drop' &&
              chain == 'prerouting') {
            bool shouldRemove = false;
            
            // روش اول: بررسی tag در comment (اگر comment وجود دارد)
            if (comment.isNotEmpty) {
              if (_hasPlatformTag(comment, platformLower)) {
                shouldRemove = true;
              }
              
              // Fallback: بررسی کلمات کلیدی (برای rules قدیمی)
              if (!shouldRemove) {
                final commentLower = comment.toLowerCase();
                for (final keyword in keywords) {
                  if (commentLower.contains(keyword) && commentLower.contains('block social')) {
                    shouldRemove = true;
                    break;
                  }
                }
              }
            }
            
            // روش دوم: اگر comment خالی است، بررسی IP-based detection
            // بررسی Address-List entries برای تشخیص پلتفرم از IP
            if (!shouldRemove && comment.isEmpty) {
              try {
                final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
                final Set<String> detectedPlatforms = {};
                
                for (final entry in allAddressList) {
                  final list = entry['list']?.toString() ?? '';
                  final address = entry['address']?.toString() ?? '';
                  
                  if (list == dstAddressList) {
                    // تشخیص پلتفرم از IP range
                    if (address.startsWith('149.154.') || address.startsWith('91.108.')) {
                      detectedPlatforms.add('telegram');
                    } else if (address.startsWith('157.240.') || address.startsWith('31.13.') || 
                        address.startsWith('129.134.') || address.startsWith('185.60.216.') ||
                        address.startsWith('66.220.144.') || address.startsWith('69.63.176.')) {
                      detectedPlatforms.add('facebook');
                      detectedPlatforms.add('instagram');
                      detectedPlatforms.add('whatsapp');
                    } else if (address.startsWith('13.107.42.') || address.startsWith('20.42.64.') || 
                        address.startsWith('20.190.128.')) {
                      detectedPlatforms.add('tiktok');
                    } else if (address.startsWith('172.217.') || address.startsWith('142.250.') ||
                        address.startsWith('74.125.') || address.startsWith('216.58.')) {
                      detectedPlatforms.add('youtube');
                    }
                  }
                }
                
                // اگر فقط این پلتفرم در Address-List وجود دارد، Raw Rule را حذف کن
                // اگر چند پلتفرم وجود دارد، Raw Rule را نگه دار (فقط Address-List entries حذف می‌شوند)
                if (detectedPlatforms.length == 1 && detectedPlatforms.contains(platformLower)) {
                  shouldRemove = true;
                } else if (detectedPlatforms.length > 1 && detectedPlatforms.contains(platformLower)) {
                  // اگر چند پلتفرم وجود دارد، Raw Rule را نگه دار
                  // فقط Address-List entries مربوط به این پلتفرم حذف می‌شوند
                  shouldRemove = false;
                } else if (detectedPlatforms.isEmpty) {
                  // اگر هیچ پلتفرمی در Address-List نیست، Raw Rule را حذف کن
                  shouldRemove = true;
                }
              } catch (e) {
                // اگر خطا در بررسی Address-List رخ داد، به عنوان fallback
                // اگر این دستگاه فقط یک Raw Rule برای Blocked-Social دارد، آن را حذف کن
                final rawRulesForDevice = allRawRules.where((r) => 
                  r['src-address']?.toString() == deviceIp &&
                  (r['dst-address-list']?.toString() == 'Blocked-Social' || 
                   r['dst-address-list']?.toString() == 'Blocked-Social-IP') &&
                  r['action']?.toString() == 'drop' &&
                  r['chain']?.toString() == 'prerouting'
                ).toList();
                
                // اگر فقط یک Raw Rule برای این دستگاه وجود دارد، آن را حذف کن
                if (rawRulesForDevice.length == 1) {
                  shouldRemove = true;
                }
              }
            }
            
            if (shouldRemove) {
              final ruleId = rule['.id']?.toString();
              if (ruleId != null) {
                try {
                  await _client!.talk(['/ip/firewall/raw/remove', '=.id=$ruleId']);
                  removedCount++;
                } catch (e) {
                  // continue
                }
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      // 3. حذف Address-List entries مربوط به این پلتفرم
      try {
        final allAddressList = await _client!.talk(['/ip/firewall/address-list/print']);
        for (final entry in allAddressList) {
          final list = entry['list']?.toString() ?? '';
          final comment = entry['comment']?.toString() ?? '';
          final address = entry['address']?.toString() ?? '';
          
          // حذف entries در Blocked-Social که comment آن‌ها شامل پلتفرم است
          if (list == 'Blocked-Social' || list == 'Blocked-Social-IP') {
            bool shouldRemoveEntry = false;
            
            // روش اول: بررسی tag "SM-Filter:Platform=" در comment
            if (comment.isNotEmpty) {
              if (_hasPlatformTag(comment, platformLower)) {
                shouldRemoveEntry = true;
              }
              
              // بررسی tag "SM-Filter:Resolved" که ممکن است مربوط به این پلتفرم باشد
              if (!shouldRemoveEntry && (comment.contains('SM-Filter:Resolved') || comment.toUpperCase().contains('SM-FILTER:RESOLVED'))) {
                // بررسی دامنه‌ها در comment
                for (final domain in domains) {
                  if (comment.contains(domain)) {
                    shouldRemoveEntry = true;
                    break;
                  }
                }
              }
            }
            
            // روش دوم: بررسی fallback (برای entries قدیمی)
            if (!shouldRemoveEntry && comment.isNotEmpty) {
              final commentLower = comment.toLowerCase();
              for (final keyword in keywords) {
                if (commentLower.contains(keyword)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // همچنین بررسی address - اگر IP range مربوط به پلتفرم است
            // برای فیسبوک: IP ranges مربوط به AS32934 (رنج‌های کامل طبق راهنما)
            if (platformLower == 'facebook' || platformLower == 'instagram' || platformLower == 'whatsapp') {
              // این IP ranges مربوط به Meta/Facebook هستند
              final facebookRanges = [
                '31.13.24.', '31.13.64.', '45.64.40.', '57.144.16.',
                '66.220.', '69.63.176.', '69.171.', '74.119.76.',
                '102.132.96.', '103.4.96.', '129.134.', '147.75.208.',
                '157.240.', '173.252.64.', '179.60.192.', '185.60.216.',
                '185.89.216.', '204.15.20.'
              ];
              for (final range in facebookRanges) {
                if (address.startsWith(range) || address.contains(range)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // برای تلگرام: IP ranges مربوط به AS62041
            if (platformLower == 'telegram') {
              final telegramRanges = ['149.154.160.', '149.154.162.', '149.154.164.', '149.154.166.', '91.108.4.', '91.108.8.', '91.108.12.', '91.108.16.', '91.108.20.', '91.108.56.'];
              for (final range in telegramRanges) {
                if (address.startsWith(range) || address.contains(range)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // برای TikTok: IP ranges
            if (platformLower == 'tiktok') {
              final tiktokRanges = ['13.107.42.', '20.42.64.', '20.190.128.'];
              for (final range in tiktokRanges) {
                if (address.startsWith(range) || address.contains(range)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // برای YouTube: IP ranges مربوط به Google (AS15169)
            if (platformLower == 'youtube') {
              final youtubeRanges = ['142.250.', '172.217.', '173.194.', '216.58.'];
              for (final range in youtubeRanges) {
                if (address.startsWith(range) || address.contains(range)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // حذف entries با comment "Resolved" که مربوط به دامنه‌های پلتفرم هستند
            if (comment.isNotEmpty && comment.contains('Resolved')) {
              final commentLower = comment.toLowerCase();
              for (final domain in domains) {
                if (commentLower.contains(domain.toLowerCase())) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            // حذف entries با comment "Block" که شامل کلمات کلیدی پلتفرم هستند
            if (comment.isNotEmpty && comment.contains('Block')) {
              final commentLower = comment.toLowerCase();
              for (final keyword in keywords) {
                if (commentLower.contains(keyword)) {
                  shouldRemoveEntry = true;
                  break;
                }
              }
            }
            
            if (shouldRemoveEntry) {
              final entryId = entry['.id']?.toString();
              if (entryId != null) {
                try {
                  await _client!.talk(['/ip/firewall/address-list/remove', '=.id=$entryId']);
                  removedCount++;
                } catch (e) {
                  // continue
                }
              }
            }
          }
        }
      } catch (e) {
        // continue
      }

      return removedCount > 0;
    } catch (e) {
      throw Exception('خطا در غیرفعال‌سازی فیلتر پلتفرم: $e');
    }
  }
}

