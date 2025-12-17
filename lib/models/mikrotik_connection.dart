/// مدل اتصال به MikroTik RouterOS
class MikroTikConnection {
  final String host;
  final int port;
  final String username;
  final String password;
  final bool useSsl;

  MikroTikConnection({
    required this.host,
    this.port = 8728,
    required this.username,
    required this.password,
    this.useSsl = false,
  });

  /// پورت واقعی با توجه به SSL
  int get actualPort {
    if (useSsl && port == 8728) {
      return 8729;
    }
    return port;
  }
}

