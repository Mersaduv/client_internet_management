/// Device Fingerprint - برای شناسایی دستگاه حتی با تغییر IP/MAC
/// 
/// این مدل از ترکیب چند ویژگی برای ایجاد یک شناسه منحصر به فرد استفاده می‌کند:
/// 1. Hostname (مهم‌ترین - معمولاً تغییر نمی‌کند)
/// 2. MAC Vendor (از OUI - 3 بایت اول MAC)
/// 3. Device Type (از hostname)
/// 4. SSID (برای wireless devices)
/// 
/// مثال: یک iPhone با hostname "iPhone-12-Pro" حتی اگر IP/MAC تغییر کند،
/// با همان hostname شناسایی می‌شود.
class DeviceFingerprint {
  /// Hostname دستگاه (مهم‌ترین شناسه)
  final String? hostname;
  
  /// MAC Vendor (3 بایت اول MAC address)
  final String? macVendor;
  
  /// نوع دستگاه (از hostname استخراج شده)
  final String? deviceType;
  
  /// SSID (برای wireless devices)
  final String? ssid;
  
  /// MAC Address فعلی (ممکن است تغییر کند)
  final String? macAddress;
  
  /// IP Address فعلی (ممکن است تغییر کند)
  final String? ipAddress;
  
  /// زمان مسدود شدن
  final DateTime? bannedAt;
  
  /// Comment در MikroTik
  final String? comment;

  DeviceFingerprint({
    this.hostname,
    this.macVendor,
    this.deviceType,
    this.ssid,
    this.macAddress,
    this.ipAddress,
    this.bannedAt,
    this.comment,
  });

  /// ایجاد Device Fingerprint از ClientInfo
  factory DeviceFingerprint.fromClientInfo(
    String? ipAddress,
    String? macAddress,
    String? hostname,
    String? ssid,
  ) {
    // استخراج MAC Vendor (3 بایت اول)
    String? macVendor;
    if (macAddress != null && macAddress.length >= 8) {
      final macParts = macAddress.split(':');
      if (macParts.length >= 3) {
        macVendor = '${macParts[0]}:${macParts[1]}:${macParts[2]}'.toUpperCase();
      }
    }

    // تشخیص Device Type از hostname
    String? deviceType;
    if (hostname != null && hostname.isNotEmpty) {
      final hostnameLower = hostname.toLowerCase();
      if (hostnameLower.contains('iphone')) {
        deviceType = 'iPhone';
      } else if (hostnameLower.contains('ipad')) {
        deviceType = 'iPad';
      } else if (hostnameLower.contains('samsung') || hostnameLower.contains('galaxy')) {
        deviceType = 'Samsung';
      } else if (hostnameLower.contains('xiaomi') || hostnameLower.contains('redmi')) {
        deviceType = 'Xiaomi';
      } else if (hostnameLower.contains('huawei')) {
        deviceType = 'Huawei';
      } else if (hostnameLower.contains('macbook') || hostnameLower.contains('imac')) {
        deviceType = 'Mac';
      } else if (hostnameLower.contains('android')) {
        deviceType = 'Android';
      }
    }

    return DeviceFingerprint(
      hostname: hostname,
      macVendor: macVendor,
      deviceType: deviceType,
      ssid: ssid,
      macAddress: macAddress,
      ipAddress: ipAddress,
    );
  }

  /// ایجاد Device Fingerprint از Map
  factory DeviceFingerprint.fromMap(Map<String, dynamic> map) {
    return DeviceFingerprint(
      hostname: map['hostname'],
      macVendor: map['mac_vendor'],
      deviceType: map['device_type'],
      ssid: map['ssid'],
      macAddress: map['mac_address'],
      ipAddress: map['ip_address'],
      bannedAt: map['banned_at'] != null
          ? DateTime.parse(map['banned_at'])
          : null,
      comment: map['comment'],
    );
  }

  /// تبدیل به Map
  Map<String, dynamic> toMap() {
    return {
      'hostname': hostname,
      'mac_vendor': macVendor,
      'device_type': deviceType,
      'ssid': ssid,
      'mac_address': macAddress,
      'ip_address': ipAddress,
      'banned_at': bannedAt?.toIso8601String(),
      'comment': comment,
    };
  }

  /// ایجاد یک شناسه منحصر به فرد برای دستگاه
  /// این شناسه از ترکیب hostname + macVendor + deviceType + ssid ساخته می‌شود
  String get fingerprintId {
    final parts = <String>[];
    
    // اولویت 1: Hostname (مهم‌ترین)
    if (hostname != null && hostname!.isNotEmpty) {
      parts.add(hostname!.toLowerCase().trim());
    }
    
    // اولویت 2: Device Type
    if (deviceType != null && deviceType!.isNotEmpty) {
      parts.add(deviceType!.toLowerCase().trim());
    }
    
    // اولویت 3: MAC Vendor
    if (macVendor != null && macVendor!.isNotEmpty) {
      parts.add(macVendor!.toUpperCase().trim());
    }
    
    // اولویت 4: SSID (برای wireless)
    if (ssid != null && ssid!.isNotEmpty) {
      parts.add(ssid!.toLowerCase().trim());
    }
    
    return parts.join('|');
  }

  /// مقایسه دو Device Fingerprint
  /// اگر hostname یکسان باشد، همان دستگاه است
  /// یا اگر macVendor + deviceType + ssid یکسان باشد
  bool matches(DeviceFingerprint other) {
    // اگر hostname یکسان باشد، قطعاً همان دستگاه است
    if (hostname != null &&
        other.hostname != null &&
        hostname!.toLowerCase().trim() == other.hostname!.toLowerCase().trim()) {
      return true;
    }

    // اگر hostname نداریم، از ترکیب macVendor + deviceType + ssid استفاده می‌کنیم
    if (hostname == null || hostname!.isEmpty) {
      if (macVendor != null &&
          other.macVendor != null &&
          macVendor!.toUpperCase() == other.macVendor!.toUpperCase() &&
          deviceType != null &&
          other.deviceType != null &&
          deviceType!.toLowerCase() == other.deviceType!.toLowerCase()) {
        // اگر SSID هم یکسان باشد، احتمال بیشتری دارد
        if (ssid != null &&
            other.ssid != null &&
            ssid!.toLowerCase() == other.ssid!.toLowerCase()) {
          return true;
        }
        // حتی بدون SSID، اگر macVendor + deviceType یکسان باشد، احتمالاً همان دستگاه است
        return true;
      }
    }

    return false;
  }

  @override
  String toString() {
    return 'DeviceFingerprint(hostname: $hostname, deviceType: $deviceType, macVendor: $macVendor, fingerprintId: $fingerprintId)';
  }
}
