import 'package:router_os_client/router_os_client.dart';

Future<void> probe(String host, {int port = 2752}) async {
  print('\n========== HOST $host:$port ==========');
  final c = RouterOSClient(address: host, user: '2026', password: '2026', useSsl: false, port: port);
  try {
    final ok = await c.login().timeout(const Duration(seconds: 6));
    print('login=$ok');
    if (!ok) return;
  } catch (e) {
    print('login FAIL: $e');
    return;
  }

  Future<void> q(String title, List<String> cmd, {int max = 12}) async {
    try {
      final rows = await c.talk(cmd).timeout(const Duration(seconds: 6));
      print('--- $title count=${rows.length} ---');
      for (var i = 0; i < rows.length && i < max; i++) {
        final m = <String, String>{};
        rows[i].forEach((k, v) => m[k.toString()] = v.toString());
        print('  [$i] $m');
      }
      if (rows.length > max) print('  ... +${rows.length - max} more');
    } catch (e) {
      print('--- $title FAIL: $e ---');
    }
  }

  await q('identity', ['/system/identity/print']);
  await q('resource', ['/system/resource/print']);
  await q('routerboard', ['/system/routerboard/print']);
  await q('packages', ['/system/package/print']);
  await q('wireless', ['/interface/wireless/print']);
  await q('wireless-security', ['/interface/wireless/security-profiles/print']);
  await q('caps-man-interfaces', ['/caps-man/interface/print']);
  await q('caps-man-config', ['/caps-man/configuration/print']);
  await q('caps-man-manager', ['/caps-man/manager/print']);
  await q('wifi', ['/interface/wifi/print']);
  await q('addresses', ['/ip/address/print']);
  await q('routes-default', ['/ip/route/print', '?dst-address=0.0.0.0/0']);
  try { c.close(); } catch (_) {}
}

Future<void> main() async {
  await probe('172.16.0.1');
  await probe('10.10.10.1');
  await probe('10.10.10.2');
  await probe('10.10.10.1', port: 8728);
  await probe('10.10.10.2', port: 8728);
  print('\nDONE');
}
