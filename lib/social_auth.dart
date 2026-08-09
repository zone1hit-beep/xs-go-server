import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Kết quả xác thực OAuth THẬT với nhà cung cấp — chỉ trả về khi token hợp lệ.
class VerifiedIdentity {
  final String providerId; // sub — định danh vĩnh viễn của người dùng bên đó
  final String? email;

  /// Nhà cung cấp KHẲNG ĐỊNH đã xác minh email này. Chỉ khi true mới được
  /// gộp vào tài khoản email/mật khẩu sẵn có — nếu không, kẻ xấu có thể tạo
  /// tài khoản bên thứ ba mang email nạn nhân rồi chiếm tài khoản XS GO.
  final bool emailVerified;
  const VerifiedIdentity(this.providerId, this.email,
      {this.emailVerified = false});
}

/// Xác thực Google ID token bằng endpoint chính chủ của Google (Google tự
/// kiểm chữ ký + hạn dùng, ta chỉ cần đối chiếu `aud` khớp Client ID của app).
/// clientIds: danh sách hợp lệ (iOS/Android/Web có thể khác Client ID nhau).
Future<VerifiedIdentity?> verifyGoogleIdToken(
    String idToken, List<String> clientIds) async {
  if (clientIds.isEmpty) return null;
  try {
    final res = await http.get(Uri.https(
        'oauth2.googleapis.com', '/tokeninfo', {'id_token': idToken}));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final aud = j['aud'] as String?;
    if (aud == null || !clientIds.contains(aud)) return null;
    final sub = j['sub'] as String?;
    if (sub == null) return null;
    // tokeninfo trả email_verified dạng chuỗi "true"/"false".
    final verified = '${j['email_verified']}' == 'true';
    return VerifiedIdentity(sub, j['email'] as String?,
        emailVerified: verified);
  } catch (_) {
    return null;
  }
}

/// Xác thực Facebook access token bằng Graph API debug_token — cần app
/// access token dạng "appId|appSecret" để chứng minh CHÍNH APP này hỏi.
Future<VerifiedIdentity?> verifyFacebookToken(
    String userToken, String appId, String appSecret) async {
  if (appId.isEmpty || appSecret.isEmpty) return null;
  try {
    final res = await http.get(Uri.https('graph.facebook.com', '/debug_token', {
      'input_token': userToken,
      'access_token': '$appId|$appSecret',
    }));
    if (res.statusCode != 200) return null;
    final data =
        (jsonDecode(res.body) as Map<String, dynamic>)['data'] as Map?;
    if (data == null) return null;
    // Phải là token NGƯỜI DÙNG của đúng app này (chặn app token / client token).
    if (data['is_valid'] != true ||
        data['app_id']?.toString() != appId ||
        (data['type'] != null && data['type'] != 'USER')) {
      return null;
    }
    final sub = data['user_id'] as String?;
    if (sub == null) return null;
    // Facebook không trả email trong debug_token — app tự gửi kèm (không
    // xác thực được nguồn email, chỉ dùng để gợi ý, KHÔNG dùng để định danh).
    return VerifiedIdentity(sub, null);
  } catch (_) {
    return null;
  }
}

/// Cache khoá công khai Apple (JWKS) — đổi vài ngày một lần, không cần tải mỗi request.
List<Map<String, dynamic>>? _appleKeysCache;
DateTime? _appleKeysFetchedAt;

Future<List<Map<String, dynamic>>> _appleKeys() async {
  final now = DateTime.now();
  if (_appleKeysCache != null &&
      _appleKeysFetchedAt != null &&
      now.difference(_appleKeysFetchedAt!) < const Duration(hours: 6)) {
    return _appleKeysCache!;
  }
  final res =
      await http.get(Uri.parse('https://appleid.apple.com/auth/keys'));
  final keys =
      (jsonDecode(res.body)['keys'] as List).cast<Map<String, dynamic>>();
  _appleKeysCache = keys;
  _appleKeysFetchedAt = now;
  return keys;
}

/// Xác thực Apple identityToken (JWT RS256) bằng khoá công khai Apple —
/// kiểm chữ ký + issuer + audience (bundle ID / Service ID của app).
Future<VerifiedIdentity?> verifyAppleIdentityToken(
    String identityToken, List<String> audiences) async {
  if (audiences.isEmpty) return null;
  try {
    // Đọc header (chưa xác thực) để biết dùng khoá nào (kid).
    final parts = identityToken.split('.');
    if (parts.length != 3) return null;
    final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
    final kid = header['kid'] as String?;
    // Ghim thuật toán: chỉ chấp nhận RS256 (Apple luôn dùng RS256) — chặn
    // mọi mưu mẹo đổi alg trong header.
    if (header['alg'] != 'RS256') return null;
    final keys = await _appleKeys();
    final match = keys.firstWhere((k) => k['kid'] == kid,
        orElse: () => const {});
    if (match.isEmpty) return null;

    final jwt = JWT.verify(
      identityToken,
      // Dùng RSAPublicKey (PEM "PUBLIC KEY"), KHÔNG dùng .cert — .cert đòi
      // PEM chứng chỉ X.509 và sẽ ném lỗi với khoá công khai thuần.
      RSAPublicKey(_jwkToPem(match)),
      // Apple KHÔNG gửi trường "typ" trong header; để mặc định thì thư viện
      // loại token ngay ("not a jwt") → Apple Sign-In không bao giờ đăng nhập được.
      checkHeaderType: false,
    );
    final payload = jwt.payload as Map<String, dynamic>;
    if (payload['iss'] != 'https://appleid.apple.com') return null;
    final aud = payload['aud'];
    final audOk = aud is String
        ? audiences.contains(aud)
        : (aud is List && aud.any((a) => audiences.contains(a)));
    if (!audOk) return null;
    final sub = payload['sub'] as String?;
    if (sub == null) return null;
    final verified = '${payload['email_verified']}' == 'true';
    // Apple "Hide My Email" trả địa chỉ trung chuyển @privaterelay.appleid.com
    // — vẫn dùng được để nhận thư, và luôn thuộc về đúng người này.
    return VerifiedIdentity(sub, payload['email'] as String?,
        emailVerified: verified);
  } catch (_) {
    return null;
  }
}

/// Dùng cho test: cho phép kiểm hàm dựng PEM từ ngoài thư viện.
String debugJwkToPem(Map<String, dynamic> jwk) => _jwkToPem(jwk);

/// Dựng PEM từ JWK RSA (n, e) — Apple trả khoá dạng JWK, package JWT cần PEM.
String _jwkToPem(Map<String, dynamic> jwk) {
  final n = base64Url.decode(base64Url.normalize(jwk['n'] as String));
  final e = base64Url.decode(base64Url.normalize(jwk['e'] as String));
  // Mã hoá DER RSAPublicKey (PKCS#1) rồi bọc SubjectPublicKeyInfo (X.509).
  List<int> encodeLen(int len) {
    if (len < 128) return [len];
    final bytes = <int>[];
    var l = len;
    while (l > 0) {
      bytes.insert(0, l & 0xff);
      l >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  List<int> encodeInt(List<int> bytes) {
    var b = bytes;
    if (b.isNotEmpty && b[0] & 0x80 != 0) b = [0, ...b];
    return [0x02, ...encodeLen(b.length), ...b];
  }

  final rsaPubKeyDer = [
    0x30,
    ...encodeLen(encodeInt(n).length + encodeInt(e).length),
    ...encodeInt(n),
    ...encodeInt(e),
  ];
  const rsaOid = [
    0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
    0x01, 0x05, 0x00, //
  ];
  final bitString = [0x03, ...encodeLen(rsaPubKeyDer.length + 1), 0x00, ...rsaPubKeyDer];
  final spki = [
    0x30,
    ...encodeLen(rsaOid.length + bitString.length),
    ...rsaOid,
    ...bitString,
  ];
  final b64 = base64.encode(spki);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----';
}
