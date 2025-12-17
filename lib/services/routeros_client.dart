import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// کلاینت برای اتصال به MikroTik RouterOS API v6
/// از پروتکل Binary API استفاده می‌کند
class RouterOSClient {
  final String address;
  final String user;
  final String password;
  final bool useSsl;
  final int port;

  Socket? _socket;
  bool _isConnected = false;
  bool _isAuthenticated = false;
  StreamSubscription<List<int>>? _socketSubscription;
  final List<int> _socketBuffer = [];
  final List<Completer<List<String>>> _pendingReads = [];

  RouterOSClient({
    required this.address,
    required this.user,
    required this.password,
    this.useSsl = false,
    this.port = 8728,
  });

  /// اتصال و احراز هویت
  Future<bool> login() async {
    try {
      // اتصال TCP Socket
      final actualPort = useSsl && port == 8728 ? 8729 : port;

      // اگر SSL استفاده می‌شود، از SecureSocket استفاده می‌کنیم
      if (useSsl) {
        _socket = await SecureSocket.connect(
          address,
          actualPort,
          onBadCertificate: (_) => true, // برای self-signed certificates
        );
      } else {
        _socket = await Socket.connect(
          address,
          actualPort,
          timeout: const Duration(seconds: 10),
        );
      }

      _isConnected = true;

      // ایجاد یک listener واحد برای socket که همیشه فعال است
      _startSocketListener();

      // کمی صبر کن تا listener آماده شود
      await Future.delayed(const Duration(milliseconds: 100));

      // احراز هویت با challenge-response
      return await _authenticate();
    } catch (e) {
      _isConnected = false;
      _isAuthenticated = false;
      _stopSocketListener();
      if (e is SocketException) {
        throw Exception('خطا در اتصال به $address:$port - ${e.message}');
      }
      throw Exception('خطا در اتصال: $e');
    }
  }

  /// شروع listener برای socket (فقط یک بار)
  void _startSocketListener() {
    if (_socket == null || _socketSubscription != null) {
      return;
    }

    _socketSubscription = _socket!.listen(
      (data) {
        _socketBuffer.addAll(data);
        _processSocketBuffer();
      },
      onError: (error) {
        // خطا را به تمام pending reads اطلاع بده
        for (var completer in _pendingReads) {
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        }
        _pendingReads.clear();
      },
      onDone: () {
        // اگر socket بسته شد، تمام pending reads را complete کن
        for (var completer in _pendingReads) {
          if (!completer.isCompleted) {
            completer.complete(<String>[]);
          }
        }
        _pendingReads.clear();
      },
      cancelOnError: false,
    );
  }

  /// توقف listener
  void _stopSocketListener() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socketBuffer.clear();
    for (var completer in _pendingReads) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Socket closed'));
      }
    }
    _pendingReads.clear();
  }

  /// پردازش buffer و کامل کردن pending reads
  void _processSocketBuffer() {
    // پردازش تمام pending reads تا جایی که ممکن است
    while (_pendingReads.isNotEmpty && _socketBuffer.isNotEmpty) {
      final completer = _pendingReads.first;
      if (completer.isCompleted) {
        _pendingReads.removeAt(0);
        continue;
      }

      final sentence = _tryReadSentence();
      if (sentence != null) {
        _pendingReads.removeAt(0);
        completer.complete(sentence);
        // بعد از complete کردن، دوباره تلاش کن (ممکن است sentence دیگری هم باشد)
        continue;
      } else {
        // داده کافی نیست، منتظر بمان
        break;
      }
    }
  }

  /// تلاش برای خواندن یک sentence از buffer
  List<String>? _tryReadSentence() {
    if (_socketBuffer.isEmpty) {
      return null;
    }

    final words = <String>[];
    int currentOffset = 0;

    while (currentOffset < _socketBuffer.length) {
      final wordResult = _decodeWord(_socketBuffer, currentOffset);
      if (wordResult == null) {
        // داده کافی نیست - داده‌های پردازش شده را نگه دار
        return null;
      }

      final word = wordResult['word'] as String;
      currentOffset = wordResult['offset'] as int;

      if (word.isEmpty) {
        // پایان sentence - حذف کل sentence از buffer
        _socketBuffer.removeRange(0, currentOffset);
        words.add(word);
        return words;
      }

      words.add(word);
    }

    // اگر sentence کامل نشده (بدون word خالی)، داده را نگه دار
    return null;
  }

  /// احراز هویت با challenge-response
  Future<bool> _authenticate() async {
    if (_socket == null || !_isConnected) {
      return false;
    }

    try {
      // پاک کردن buffer قبل از شروع احراز هویت
      _socketBuffer.clear();
      _pendingReads.clear();
      
      // ارسال نام کاربری
      await _writeSentence(['/login', '=name=$user']);

      // کمی صبر کن تا داده ارسال شود
      await Future.delayed(const Duration(milliseconds: 50));

      // دریافت چالش - با timeout
      final challengeResponse = await _readSentenceWithTimeout();
      if (challengeResponse.isEmpty) {
        throw Exception('پاسخ challenge خالی است');
      }

      // استخراج challenge token
      // پاسخ challenge معمولاً به این شکل است: ['!done', '=ret=xxxxxxxx', '']
      // یا ['!trap', '=message=...']
      String? challengeToken;
      
      // بررسی !trap
      if (challengeResponse.isNotEmpty && challengeResponse[0] == '!trap') {
        String errorMsg = 'خطا در دریافت challenge';
        for (var word in challengeResponse) {
          if (word.startsWith('=message=')) {
            errorMsg = word.substring(9);
            break;
          }
        }
        throw Exception(errorMsg);
      }
      
      // جستجوی =ret= در تمام کلمات
      // توجه: در RouterOS API، challenge ممکن است در کلمات مختلف باشد
      // فرمت معمول: ['!done', '=ret=xxxxxxxx', ''] 
      // challenge token معمولاً 16 byte است (32 hex character)
      for (var word in challengeResponse) {
        // بررسی =ret=
        if (word.startsWith('=ret=')) {
          challengeToken = word.substring(5);
          break;
        }
      }

      if (challengeToken == null || challengeToken.isEmpty) {
        throw Exception('Challenge token یافت نشد. پاسخ کامل: $challengeResponse');
      }
      
      // حذف فاصله‌ها و کاراکترهای اضافی از challenge token
      challengeToken = challengeToken.trim();
      
      // بررسی طول challenge token (معمولاً 32 hex character = 16 bytes)
      if (challengeToken.length < 16) {
        throw Exception('Challenge token کوتاه است: $challengeToken (طول: ${challengeToken.length})');
      }

      // محاسبه پاسخ MD5
      // فرمت: MD5(0x00 + password_bytes + challenge_bytes)
      // توجه: password باید به صورت UTF-8 encode شود (نه ASCII)
      final passwordBytes = utf8.encode(password);
      
      // تبدیل challenge token از hex string به bytes
      // challenge token معمولاً یک hex string است (مثلاً "a1b2c3d4...")
      final challengeBytes = _hexToBytes(challengeToken);
      
      // ساخت byte array: [0x00] + password_bytes + challenge_bytes
      // این دقیقاً همان فرمتی است که librouteros در Python استفاده می‌کند
      final combined = Uint8List(1 + passwordBytes.length + challengeBytes.length);
      combined[0] = 0; // byte اول باید 0x00 باشد
      combined.setRange(1, 1 + passwordBytes.length, passwordBytes);
      combined.setRange(
          1 + passwordBytes.length, combined.length, challengeBytes);

      // محاسبه MD5 hash از combined bytes
      final md5Hash = md5.convert(combined);
      
      // response باید به فرمت 00{md5_hash_lowercase} باشد
      // توجه: MD5 hash باید به صورت hexadecimal lowercase باشد
      // و "00" در ابتدا باید اضافه شود
      final responseHash = '00${md5Hash.toString().toLowerCase()}';

      // ارسال پاسخ
      // توجه: در RouterOS API، response باید دقیقاً به این فرمت باشد:
      // /login
      // =name=username
      // =response=00{md5_hash}
      await _writeSentence(['/login', '=name=$user', '=response=$responseHash']);

      // کمی صبر کن تا داده ارسال شود
      await Future.delayed(const Duration(milliseconds: 50));

      // بررسی موفقیت احراز هویت - با timeout
      final authResponse = await _readSentenceWithTimeout();
      if (authResponse.isNotEmpty && authResponse[0] == '!done') {
        _isAuthenticated = true;
        return true;
      }

      // اگر !trap دریافت شد، خطا را استخراج کن
      if (authResponse.isNotEmpty && authResponse[0] == '!trap') {
        String errorMsg = 'خطا در احراز هویت';
        for (var word in authResponse) {
          if (word.startsWith('=message=')) {
            errorMsg = word.substring(9);
            break;
          }
        }
        throw Exception(errorMsg);
      }

      throw Exception('احراز هویت ناموفق. پاسخ: $authResponse');
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('خطا در احراز هویت: $e');
    }
  }

  /// خواندن sentence با timeout
  Future<List<String>> _readSentenceWithTimeout() async {
    return await _readSentence().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw Exception('Timeout در خواندن پاسخ از RouterOS');
      },
    );
  }

  /// ارسال دستور و دریافت پاسخ
  Future<List<Map<String, String>>> talk(List<String> command) async {
    if (!_isConnected || !_isAuthenticated) {
      throw Exception('اتصال برقرار نشده یا احراز هویت انجام نشده');
    }

    try {
      // ارسال دستور
      await _writeSentence(command);

      // دریافت پاسخ‌ها
      final results = <Map<String, String>>[];
      while (true) {
        final sentence = await _readSentence();
        if (sentence.isEmpty) {
          break;
        }

        if (sentence[0] == '!done') {
          break;
        } else if (sentence[0] == '!trap') {
          final error = sentence.length > 1 ? sentence[1] : 'خطای ناشناخته';
          throw Exception('خطا از RouterOS: $error');
        } else if (sentence[0] == '!re') {
          // یک رکورد دریافت شده
          final record = <String, String>{};
          for (var i = 1; i < sentence.length; i++) {
            final word = sentence[i];
            if (word.startsWith('=')) {
              final eqIndex = word.indexOf('=', 1);
              if (eqIndex > 0) {
                final key = word.substring(1, eqIndex);
                final value = word.substring(eqIndex + 1);
                record[key] = value;
              } else {
                final key = word.substring(1);
                record[key] = '';
              }
            }
          }
          if (record.isNotEmpty) {
            results.add(record);
          }
        } else if (sentence[0] == '!fatal') {
          throw Exception('خطای fatal از RouterOS');
        }
      }

      return results;
    } catch (e) {
      throw Exception('خطا در اجرای دستور: $e');
    }
  }

  /// نوشتن یک sentence به socket
  Future<void> _writeSentence(List<String> words) async {
    if (_socket == null) {
      throw Exception('Socket متصل نیست');
    }

    final buffer = <int>[];
    for (var word in words) {
      final wordBytes = utf8.encode(word);
      buffer.addAll(_encodeWord(wordBytes));
    }
    // اضافه کردن terminator (0x00)
    buffer.add(0x00);

    _socket!.add(buffer);
    await _socket!.flush();
  }

  /// خواندن یک sentence از socket
  Future<List<String>> _readSentence() async {
    if (_socket == null || _socketSubscription == null) {
      throw Exception('Socket متصل نیست');
    }

    // اگر داده در buffer موجود است، سعی کن sentence را بخوان
    final sentence = _tryReadSentence();
    if (sentence != null) {
      return sentence;
    }

    // اگر sentence کامل نشده، یک completer ایجاد کن و منتظر بمان
    final completer = Completer<List<String>>();
    _pendingReads.add(completer);

    // پردازش دوباره buffer (ممکن است داده جدید آمده باشد)
    _processSocketBuffer();

    // Timeout برای جلوگیری از hang
    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        _pendingReads.remove(completer);
        completer.completeError(Exception('Timeout در خواندن پاسخ'));
      }
    });

    return completer.future;
  }

  /// Encode یک word به فرمت باینری MikroTik
  List<int> _encodeWord(List<int> wordBytes) {
    final length = wordBytes.length;
    final result = <int>[];

    if (length < 0x80) {
      // 1 byte length
      result.add(length);
    } else if (length < 0x4000) {
      // 2 byte length
      result.add((length >> 8) | 0x80);
      result.add(length & 0xFF);
    } else if (length < 0x200000) {
      // 3 byte length
      result.add((length >> 16) | 0xC0);
      result.add((length >> 8) & 0xFF);
      result.add(length & 0xFF);
    } else if (length < 0x10000000) {
      // 4 byte length
      result.add((length >> 24) | 0xE0);
      result.add((length >> 16) & 0xFF);
      result.add((length >> 8) & 0xFF);
      result.add(length & 0xFF);
    } else {
      // 5 byte length
      result.add(0xF0);
      result.add((length >> 24) & 0xFF);
      result.add((length >> 16) & 0xFF);
      result.add((length >> 8) & 0xFF);
      result.add(length & 0xFF);
    }

    result.addAll(wordBytes);
    return result;
  }

  /// Decode یک word از فرمت باینری MikroTik
  Map<String, dynamic>? _decodeWord(List<int> buffer, int offset) {
    if (offset >= buffer.length) {
      return null;
    }

    int length;
    int bytesRead;

    final firstByte = buffer[offset];
    if ((firstByte & 0x80) == 0) {
      // 1 byte length
      length = firstByte;
      bytesRead = 1;
    } else if ((firstByte & 0xC0) == 0x80) {
      // 2 byte length
      if (offset + 1 >= buffer.length) return null;
      length = ((firstByte & 0x7F) << 8) | buffer[offset + 1];
      bytesRead = 2;
    } else if ((firstByte & 0xE0) == 0xC0) {
      // 3 byte length
      if (offset + 2 >= buffer.length) return null;
      length = ((firstByte & 0x1F) << 16) |
          (buffer[offset + 1] << 8) |
          buffer[offset + 2];
      bytesRead = 3;
    } else if ((firstByte & 0xF0) == 0xE0) {
      // 4 byte length
      if (offset + 3 >= buffer.length) return null;
      length = ((firstByte & 0x0F) << 24) |
          (buffer[offset + 1] << 16) |
          (buffer[offset + 2] << 8) |
          buffer[offset + 3];
      bytesRead = 4;
    } else {
      // 5 byte length
      if (offset + 4 >= buffer.length) return null;
      length = (buffer[offset + 1] << 24) |
          (buffer[offset + 2] << 16) |
          (buffer[offset + 3] << 8) |
          buffer[offset + 4];
      bytesRead = 5;
    }

    if (offset + bytesRead + length > buffer.length) {
      return null; // داده کافی نیست
    }

    final wordBytes = buffer.sublist(offset + bytesRead, offset + bytesRead + length);
    final word = length == 0 ? '' : utf8.decode(wordBytes);

    return {
      'word': word,
      'offset': offset + bytesRead + length,
    };
  }

  /// تبدیل hex string به bytes
  Uint8List _hexToBytes(String hex) {
    // حذف فاصله‌ها و تبدیل به lowercase
    hex = hex.replaceAll(' ', '').toLowerCase();
    if (hex.length % 2 != 0) {
      throw Exception('طول hex string باید زوج باشد: $hex');
    }
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  /// بستن اتصال
  void close() {
    _stopSocketListener();
    _socket?.destroy();
    _socket = null;
    _isConnected = false;
    _isAuthenticated = false;
  }

  bool get isConnected => _isConnected && _isAuthenticated;
}

