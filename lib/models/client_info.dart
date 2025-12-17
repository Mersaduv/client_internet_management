/// اطلاعات کلاینت متصل به MikroTik
class ClientInfo {
  final String type; // hotspot, wireless, dhcp, ppp
  final String source;
  final String? user;
  final String? name;
  final String? ipAddress;
  final String? macAddress;
  final String? hostName;
  final String? uptime;
  final String? bytesIn;
  final String? bytesOut;
  final String? loginBy;
  final String? server;
  final String? id;
  final String? interface;
  final String? ssid;
  final String? signalStrength;
  final String? service;
  final String? callerId;
  final String? status;
  final String? expiresAfter;
  final Map<String, dynamic> rawData;

  ClientInfo({
    required this.type,
    required this.source,
    this.user,
    this.name,
    this.ipAddress,
    this.macAddress,
    this.hostName,
    this.uptime,
    this.bytesIn,
    this.bytesOut,
    this.loginBy,
    this.server,
    this.id,
    this.interface,
    this.ssid,
    this.signalStrength,
    this.service,
    this.callerId,
    this.status,
    this.expiresAfter,
    required this.rawData,
  });

  factory ClientInfo.fromMap(Map<String, dynamic> map) {
    return ClientInfo(
      type: map['type'] ?? 'unknown',
      source: map['source'] ?? 'unknown',
      user: map['user'],
      name: map['name'],
      ipAddress: map['ip_address'] ?? map['address'],
      macAddress: map['mac_address'] ?? map['mac-address'],
      hostName: map['host_name'] ?? map['host-name'],
      uptime: map['uptime'],
      bytesIn: map['bytes_in'] ?? map['bytes-in'],
      bytesOut: map['bytes_out'] ?? map['bytes-out'],
      loginBy: map['login_by'] ?? map['login-by'],
      server: map['server'],
      id: map['id'] ?? map['.id'],
      interface: map['interface'],
      ssid: map['ssid'],
      signalStrength: map['signal_strength'] ?? map['signal-strength'],
      service: map['service'],
      callerId: map['caller_id'] ?? map['caller-id'],
      status: map['status'],
      expiresAfter: map['expires_after'] ?? map['expires-after'],
      rawData: map,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'source': source,
      'user': user,
      'name': name,
      'ip_address': ipAddress,
      'mac_address': macAddress,
      'host_name': hostName,
      'uptime': uptime,
      'bytes_in': bytesIn,
      'bytes_out': bytesOut,
      'login_by': loginBy,
      'server': server,
      'id': id,
      'interface': interface,
      'ssid': ssid,
      'signal_strength': signalStrength,
      'service': service,
      'caller_id': callerId,
      'status': status,
      'expires_after': expiresAfter,
      'raw_data': rawData,
    };
  }
}

