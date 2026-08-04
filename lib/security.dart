import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Đăng nhập/JWT tự cài (HS256) + băm mật khẩu PBKDF2-HMAC-SHA256.
/// Không phụ thuộc package bcrypt/jwt để giảm rủi ro `pub get` treo.

/// Giá trị secret MẶC ĐỊNH (không an toàn) — chỉ dùng cho dev.
const kDefaultJwtSecret = 'xs-go-dev-secret-change-me';

/// Bí mật ký JWT — production BẮT BUỘC đặt qua env XSGO_JWT_SECRET.
final String _jwtSecret =
    (String.fromEnvironment('XSGO_JWT_SECRET').isNotEmpty)
        ? const String.fromEnvironment('XSGO_JWT_SECRET')
        : (_env('XSGO_JWT_SECRET') ?? kDefaultJwtSecret);

/// True nếu đang ký JWT bằng secret mặc định (public) — KHÔNG an toàn cho production.
/// Ai biết secret này có thể tự làm giả JWT và mạo danh mọi tài khoản.
bool get usingDefaultJwtSecret => _jwtSecret == kDefaultJwtSecret;

String? _env(String k) {
  final v = _platformEnv[k];
  return (v == null || v.isEmpty) ? null : v;
}

// nạp một lần từ Platform.environment (đặt ở server.dart)
Map<String, String> _platformEnv = const {};
void configureSecurity(Map<String, String> env) {
  _platformEnv = env;
}

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _b64urlDecode(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

// ---------- Mật khẩu (PBKDF2-HMAC-SHA256) ----------

final _rnd = Random.secure();

String _randomSalt([int len = 16]) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = _rnd.nextInt(256);
  }
  return _b64url(b);
}

List<int> _pbkdf2(String password, List<int> salt,
    {int iterations = 100000, int dkLen = 32}) {
  final hmac = Hmac(sha256, utf8.encode(password));
  final out = <int>[];
  var blockIndex = 1;
  while (out.length < dkLen) {
    // INT_32_BE(blockIndex)
    final block = <int>[
      ...salt,
      (blockIndex >> 24) & 0xff,
      (blockIndex >> 16) & 0xff,
      (blockIndex >> 8) & 0xff,
      blockIndex & 0xff,
    ];
    var u = hmac.convert(block).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.addAll(t);
    blockIndex++;
  }
  return out.sublist(0, dkLen);
}

/// Trả về "salt$hash" (đều base64url) để lưu 1 cột.
String hashPassword(String password) {
  final salt = _randomSalt();
  final dk = _pbkdf2(password, _b64urlDecode(salt));
  return '$salt\$${_b64url(dk)}';
}

bool verifyPassword(String password, String stored) {
  final parts = stored.split('\$');
  if (parts.length != 2) return false;
  final salt = _b64urlDecode(parts[0]);
  final expected = _b64urlDecode(parts[1]);
  final dk = _pbkdf2(password, salt);
  if (dk.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < dk.length; i++) {
    diff |= dk[i] ^ expected[i];
  }
  return diff == 0;
}

// ---------- JWT HS256 ----------

String signJwt(Map<String, dynamic> claims,
    {Duration ttl = const Duration(days: 30)}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final header = {'alg': 'HS256', 'typ': 'JWT'};
  final payload = {
    ...claims,
    'iat': now,
    'exp': now + ttl.inSeconds,
  };
  final h = _b64url(utf8.encode(jsonEncode(header)));
  final p = _b64url(utf8.encode(jsonEncode(payload)));
  final signingInput = '$h.$p';
  final sig = Hmac(sha256, utf8.encode(_jwtSecret))
      .convert(utf8.encode(signingInput))
      .bytes;
  return '$signingInput.${_b64url(sig)}';
}

/// So sánh chuỗi constant-time — chống timing attack dò chữ ký.
bool _constEq(String a, String b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return d == 0;
}

/// Trả về payload nếu hợp lệ & chưa hết hạn, ngược lại null.
Map<String, dynamic>? verifyJwt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  final signingInput = '${parts[0]}.${parts[1]}';
  final expected = _b64url(
      Hmac(sha256, utf8.encode(_jwtSecret))
          .convert(utf8.encode(signingInput))
          .bytes);
  if (!_constEq(expected, parts[2])) return null;
  final payload =
      jsonDecode(utf8.decode(_b64urlDecode(parts[1]))) as Map<String, dynamic>;
  final exp = payload['exp'] as int?;
  if (exp != null &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 > exp) {
    return null;
  }
  return payload;
}
