import '../models/mikrotik_connection.dart';
import '../models/client_info.dart';
import 'routeros_client_v2.dart' show RouterOSClientV2;

/// سرویس برای مدیریت اتصال و عملیات MikroTik RouterOS
/// مشابه endpointهای /api/clients/* در پروژه Python
class MikroTikService {
  RouterOSClientV2? _client;

  /// اتصال به MikroTik RouterOS
  Future<bool> connect(MikroTikConnection connection) async {
    try {
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
      }
      return success;
    } catch (e) {
      _client = null;
      throw Exception('خطا در اتصال: $e');
    }
  }

  /// بررسی اتصال
  bool get isConnected => _client?.isConnected ?? false;

  /// بستن اتصال
  void disconnect() {
    _client?.close();
    _client = null;
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

  /// مسدود کردن کلاینت
  /// مشابه POST /api/clients/ban
  /// از چند بخش مسدود می‌کند:
  /// 1. Firewall Input Chain
  /// 2. Firewall Forward Chain (بر اساس IP)
  /// 3. Firewall Forward Chain (بر اساس MAC - مستقل از IP)
  /// 4. DHCP Block Access
  /// 5. Wireless Access List
  Future<bool> banClient(String ipAddress, {String? macAddress}) async {
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

      // بررسی اینکه آیا قبلاً مسدود شده است
      try {
        final filters = await _client!.talk(['/ip/firewall/filter/print']);
        for (var f in filters) {
          if ((f['chain'] == 'input' || f['chain'] == 'forward') &&
              f['src-address'] == ipAddress &&
              f['action'] == 'drop') {
            // قبلاً مسدود شده است
            return true;
          }
        }
      } catch (e) {
        // ignore
      }

      final comment = 'Banned via Flutter App';

      // 1. Firewall Input Chain - مسدود کردن ترافیک ورودی به روتر
      try {
        final inputCommand = ['/ip/firewall/filter/add', '=chain=input', '=src-address=$ipAddress', '=action=drop', '=comment=$comment - Input'];
        if (macToUse != null) {
          inputCommand.add('=src-mac-address=$macToUse');
        }
        await _client!.talk(inputCommand);
      } catch (e) {
        // ignore - ادامه بده
      }

      // 2. Firewall Forward Chain - مسدود کردن ترافیک forward (خروجی به اینترنت)
      try {
        final forwardCommand = ['/ip/firewall/filter/add', '=chain=forward', '=src-address=$ipAddress', '=action=drop', '=comment=$comment - Forward'];
        if (macToUse != null) {
          forwardCommand.add('=src-mac-address=$macToUse');
        }
        await _client!.talk(forwardCommand);
      } catch (e) {
        // ignore - ادامه بده
      }

      // 3. Firewall Forward MAC Chain - مسدود کردن بر اساس MAC (مستقل از IP)
      if (macToUse != null) {
        try {
          await _client!.talk([
            '/ip/firewall/filter/add',
            '=chain=forward',
            '=src-mac-address=$macToUse',
            '=action=drop',
            '=comment=$comment - Forward MAC Only',
          ]);
        } catch (e) {
          // ignore - ادامه بده
        }
      }

      // 4. DHCP Block Access - Block کردن DHCP lease
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

      // 5. Wireless Access List - مسدود کردن اتصال وای‌فای
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

      return true;
    } catch (e) {
      throw Exception('خطا در مسدود کردن کلاینت: $e');
    }
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

      // 1. حذف Firewall Rules
      try {
        final filters = await _client!.talk(['/ip/firewall/filter/print']);
        for (var f in filters) {
          bool shouldRemove = false;
          if (f['src-address'] == ipAddress) {
            shouldRemove = true;
          }
          if (macToUse != null && f['src-mac-address'] == macToUse) {
            shouldRemove = true;
          }

          if (shouldRemove &&
              f['action'] == 'drop' &&
              (f['chain'] == 'input' || f['chain'] == 'forward')) {
            final ruleId = f['.id'];
            if (ruleId != null) {
              try {
                await _client!.talk(['/ip/firewall/filter/remove', '=.id=$ruleId']);
                removedCount++;
              } catch (e) {
                // ignore
              }
            }
          }
        }
      } catch (e) {
        // ignore
      }

      // 2. رفع Block از DHCP Lease
      if (macToUse != null) {
        try {
          final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
          for (var lease in dhcpLeases) {
            final leaseMac = lease['mac-address']?.toString().toUpperCase();
            if (leaseMac == macToUse.toUpperCase()) {
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
              break;
            }
          }
        } catch (e) {
          // ignore
        }
      }

      // 3. رفع Block از Wireless Access List
      if (macToUse != null) {
        try {
          final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
          for (var acl in accessList) {
            final aclMac = acl['mac-address']?.toString().toUpperCase();
            if (aclMac == macToUse.toUpperCase() &&
                (acl['action'] == 'reject' || acl['action'] == 'deny')) {
              final aclId = acl['.id'];
              if (aclId != null) {
                try {
                  // حذف از access list
                  await _client!.talk([
                    '/interface/wireless/access-list/remove',
                    '=.id=$aclId',
                  ]);
                } catch (e) {
                  // ignore
                }
              }
              break;
            }
          }
        } catch (e) {
          // ignore
        }
      }

      return removedCount > 0;
    } catch (e) {
      throw Exception('خطا در رفع مسدودیت کلاینت: $e');
    }
  }

  /// دریافت لیست کلاینت‌های مسدود شده
  /// مشابه POST /api/clients/banned
  /// از firewall rules استفاده می‌کند (نه address-list)
  Future<List<Map<String, dynamic>>> getBannedClients() async {
    if (_client == null || !isConnected) {
      throw Exception('اتصال برقرار نشده');
    }

    try {
      // پیدا کردن firewall rules با action=drop
      final filters = await _client!.talk(['/ip/firewall/filter/print']);
      
      // فیلتر کردن rules با action=drop و chain=input یا forward
      final banRules = <Map<String, dynamic>>[];
      for (var f in filters) {
        if (f['action'] == 'drop' &&
            (f['chain'] == 'input' || f['chain'] == 'forward')) {
          banRules.add(f);
        }
      }

      // گروه‌بندی rules بر اساس IP
      final ipToRules = <String, Map<String, dynamic>>{};
      for (var rule in banRules) {
        final ip = rule['src-address']?.toString();
        final mac = rule['src-mac-address']?.toString();
        
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
      }

      // تبدیل به لیست
      final bannedClients = ipToRules.values.toList();

      // افزودن اطلاعات DHCP و Wireless
      for (var client in bannedClients) {
        final ip = client['address'] as String;
        final mac = client['mac_address'] as String?;

        // پیدا کردن MAC از DHCP یا ARP اگر موجود نباشد
        if (mac == null) {
          try {
            final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
            for (var lease in dhcpLeases) {
              if (lease['address'] == ip) {
                client['mac_address'] = lease['mac-address'];
                break;
              }
            }
            
            if (client['mac_address'] == null) {
              final arpEntries = await _client!.talk(['/ip/arp/print']);
              for (var arp in arpEntries) {
                if (arp['address'] == ip) {
                  client['mac_address'] = arp['mac-address'];
                  break;
                }
              }
            }
          } catch (e) {
            // ignore
          }
        }

        // بررسی DHCP Block Access
        if (client['mac_address'] != null) {
          try {
            final dhcpLeases = await _client!.talk(['/ip/dhcp-server/lease/print']);
            for (var lease in dhcpLeases) {
              final leaseMac = lease['mac-address']?.toString().toUpperCase();
              if (leaseMac == (client['mac_address'] as String).toUpperCase()) {
                client['dhcp_blocked'] = lease['block-access'] == 'yes';
                break;
              }
            }
          } catch (e) {
            // ignore
          }
        }

        // بررسی Wireless Access List
        if (client['mac_address'] != null) {
          try {
            final accessList = await _client!.talk(['/interface/wireless/access-list/print']);
            for (var acl in accessList) {
              final aclMac = acl['mac-address']?.toString().toUpperCase();
              if (aclMac == (client['mac_address'] as String).toUpperCase()) {
                client['wireless_blocked'] = acl['action'] == 'reject' || acl['action'] == 'deny';
                break;
              }
            }
          } catch (e) {
            // ignore
          }
        }
      }

      return bannedClients;
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
  Future<String?> getDeviceIp() async {
    if (_client == null || !isConnected) {
      return null;
    }
    try {
      // استفاده از ARP table برای پیدا کردن IP دستگاه
      final arpEntries = await _client!.talk(['/ip/arp/print']);
      if (arpEntries.isNotEmpty) {
        // استفاده از IP اول به عنوان IP دستگاه
        return arpEntries.first['address'];
      }
      return null;
    } catch (e) {
      return null;
    }
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
}

