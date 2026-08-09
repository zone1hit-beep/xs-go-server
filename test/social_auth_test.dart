import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/social_auth.dart';

/// Kiểm tra lớp xác thực đăng nhập mạng xã hội.
///
/// Phần quan trọng nhất là JWK→PEM cho khoá Apple: code tự dựng ASN.1 nên rất
/// dễ sai lặng lẽ (sai thì MỌI lần đăng nhập Apple đều hỏng). Test tải khoá
/// THẬT từ Apple và kiểm PEM dựng ra có đúng chuẩn không.
void main() {
  group('Apple JWKS', () {
    test('dựng được PEM hợp lệ từ khoá công khai thật của Apple', () async {
      final res =
          await http.get(Uri.parse('https://appleid.apple.com/auth/keys'));
      expect(res.statusCode, 200, reason: 'không tải được JWKS của Apple');
      final keys =
          (jsonDecode(res.body)['keys'] as List).cast<Map<String, dynamic>>();
      expect(keys, isNotEmpty);

      for (final k in keys) {
        final pem = debugJwkToPem(k);
        expect(pem, startsWith('-----BEGIN PUBLIC KEY-----'));
        expect(pem.trim(), endsWith('-----END PUBLIC KEY-----'));

        // Giải ngược PEM và kiểm cấu trúc DER: SEQUENCE bọc ngoài, và modulus
        // đúng độ dài Apple dùng (RSA 2048 → 256 byte).
        final body = pem
            .replaceAll('-----BEGIN PUBLIC KEY-----', '')
            .replaceAll('-----END PUBLIC KEY-----', '')
            .replaceAll('\n', '');
        final der = base64.decode(body);
        expect(der[0], 0x30, reason: 'DER phải mở đầu bằng SEQUENCE');

        final n = base64Url.decode(base64Url.normalize(k['n'] as String));
        expect(n.length, 256, reason: 'Apple dùng RSA-2048');
        // Modulus phải nằm nguyên vẹn trong DER.
        expect(_contains(der, n), isTrue,
            reason: 'PEM dựng ra không chứa modulus gốc → sai ASN.1');
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('token rác bị từ chối, không ném lỗi ra ngoài', () async {
      expect(await verifyAppleIdentityToken('rác', ['com.xsgo.xsGo']), isNull);
      expect(await verifyAppleIdentityToken('a.b.c', ['com.xsgo.xsGo']), isNull);
      // Chưa cấu hình audience → luôn từ chối (fail-closed).
      expect(await verifyAppleIdentityToken('a.b.c', const []), isNull);
    });
  });


  group('Apple end-to-end (khoá test tự sinh, giả lập đúng token Apple)', () {
    // Khoá RSA CHỈ DÙNG CHO TEST — không phải bí mật thật.
    const testPrivPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCd+uTvaUnPfXwN
p8lGNxeYbYlfopTX2xJkT8f9Pzhew8CL/9/OgfpjuYK16Wu/fR8dNw5DCZhJRWgJ
8hkWpqbAGCGQduOc70tX54faQ3LK2J88tKzD+wC7m8hEuyEXFjzIXl7jIjf87LKZ
+H98hkFiQ5Dzi3Wz0pdehRokb2zsZLb0r8ZvKzenPwrzfzFskHFrrlTM4IONB5hE
RHCuvlwJDcTYFAR+qATVZMu0xYDxg25Ejvx1rfUrNknP3nqWmlMBgg7VSiz7GGLa
inPtEBXvhzA/NHPkTFQd/pwXDp8KtcdsE59KfxbYeT1E/yhu27maM7Nzxqkh4PyC
rIygI9KDAgMBAAECggEAD6B0ai+CsEDmtyhprcW1UnaYqBpvmV/U1JIFDkqP9jps
HsJouQdSZUWXEGIj2QU0wVxjehjGNOPmBACBSs72n6RuGC7VGlOb+E4GuihXKol9
oYZIW0/GJXNQvru5QjdeO9OvPyMbYVa93qJzZItDMcfNMXS8vSo6SYyQ/BmphJh/
UYjEEgqBTnPwXd/Rjql0CJur1ri6s/5bxoAMHKhS9+ZlD6k5Yl5FWnHyi0iwKm3x
x0V0G23fzj5x/lTKG3mOpySp6pB6ZGfd/oY7E6RIP+TLt9hrU3RsEh2VI5TZuQ2v
sO8VPiuskO1rPeS6Zv5Kw6cuSlFH3de1XrA1c+9XQQKBgQDQCf/sI8njwUWAKT0q
/cTSCzYAIyDGVW5zMmCggsSTHYDyBkzPCn64mhoL858ZoCCSGWzxpAElVVWlTZ8C
3gvkpZkURhZrzeMjcqVfJVNUPD+vGxTblj1f7ahQgU48Yjq9forqE0IRhvH3IWIu
yPn61kf0uO53WCCeSUv68VCiHQKBgQDCZoYkAOEkk/HLzEBc2BaZgOqElp0Je7CI
LpfIuEeECnTUDfnR5xB02gQ1EeXR3sg1lAxtI/JKq7f8JU90+Pbql83EkVGtL6Vo
2tP1UzA6vj4YSIBaBWgqy5lMsobjotFBX6EbDN5z602Bt5HoBSggM8jqy0oMwT0H
g9G3HRolHwKBgFDdMi8VkioHO/6fCPmm/lQuq2TOQrUVDAOW91wsuD/+3do1fLGV
gMA8lhdDMPqC9WYUn/YlK5TZYJsKWt6AdNsBS0lIHPr2Ym2q6IDdP1CkwpRL0IWy
FlUtSZlRSZnLDM4PW+u0ZJ/vdin7PfC1igVoOTv0jiyxgqxEDVaTaiY5AoGBAJrR
jajkrmk0DZARhXyrdywe+CZJ0Jy5zfhWqvjmkcX9kddDnh5ll7yH2Gvvagj/FJFe
65qL0y1WnnsHt8Tfdb2U0gHm/ZYgaOodxEoPS0ytL8SlENsgjTnv1ZG4aCaoB2C5
6RMi55KH5b0V1fRjDva+ZxdeeQW5a4Itn/nmCmlfAoGAC1cm63dHrqa2FgsqGxEw
r/4uZ10O3/WmgJl/JlW1JD6zWDGLrCBQU24IZJi0c62mRqjv+Z2fzlkmPJc3cXHy
TT6uo53wvWDMN77QKrDUv+glcc6iIuso8cP2DO28ouCB+v+812UANbIvJIU099aJ
rIpryH7uyJmqXiv63a78aJI=
-----END PRIVATE KEY-----''';
    const testJwk = r'''{"kty": "RSA", "kid": "testkid", "use": "sig", "alg": "RS256", "n": "nfrk72lJz318DafJRjcXmG2JX6KU19sSZE_H_T84XsPAi__fzoH6Y7mCtelrv30fHTcOQwmYSUVoCfIZFqamwBghkHbjnO9LV-eH2kNyytifPLSsw_sAu5vIRLshFxY8yF5e4yI3_Oyymfh_fIZBYkOQ84t1s9KXXoUaJG9s7GS29K_Gbys3pz8K838xbJBxa65UzOCDjQeYRERwrr5cCQ3E2BQEfqgE1WTLtMWA8YNuRI78da31KzZJz956lppTAYIO1Uos-xhi2opz7RAV74cwPzRz5ExUHf6cFw6fCrXHbBOfSn8W2Hk9RP8obtu5mjOzc8apIeD8gqyMoCPSgw", "e": "AQAB"}''';

    String signAppleLikeToken({String aud = 'com.xsgo.xsGo', int expIn = 600}) {
      final jwt = JWT(
        {
          'iss': 'https://appleid.apple.com',
          'aud': aud,
          'sub': '001234.abcdef.5678',
          'email': 'a@privaterelay.appleid.com',
          'email_verified': 'true',
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + expIn,
        },
        // Apple KHÔNG gửi 'typ' — đây chính là chỗ từng làm hỏng verify.
        header: {'kid': 'testkid', 'alg': 'RS256'},
      );
      return jwt.sign(RSAPrivateKey(testPrivPem), algorithm: JWTAlgorithm.RS256);
    }

    test('token Apple hợp lệ verify được bằng PEM dựng từ JWK', () {
      final jwk = jsonDecode(testJwk) as Map<String, dynamic>;
      final token = signAppleLikeToken();
      final decoded = JWT.verify(
        token,
        RSAPublicKey(debugJwkToPem(jwk)), // KHÔNG dùng .cert (ném RangeError)
        checkHeaderType: false,
      );
      final p = decoded.payload as Map<String, dynamic>;
      expect(p['sub'], '001234.abcdef.5678');
      expect(p['iss'], 'https://appleid.apple.com');
    });

    test('REGRESSION: RSAPublicKey.cert ném lỗi với PEM khoá công khai', () {
      final jwk = jsonDecode(testJwk) as Map<String, dynamic>;
      // Nếu một ngày thư viện đổi và .cert chạy được thì test này báo để rà lại.
      expect(() => RSAPublicKey.cert(debugJwkToPem(jwk)), throwsA(anything));
    });

    test('token hết hạn bị từ chối', () {
      final jwk = jsonDecode(testJwk) as Map<String, dynamic>;
      final expired = signAppleLikeToken(expIn: -60);
      expect(
          () => JWT.verify(expired, RSAPublicKey(debugJwkToPem(jwk)),
              checkHeaderType: false),
          throwsA(isA<JWTExpiredException>()));
    });
  });

  group('fail-closed khi thiếu cấu hình', () {
    test('Google: không có client ID thì từ chối', () async {
      expect(await verifyGoogleIdToken('bất-kỳ', const []), isNull);
    });
    test('Google: token rác bị từ chối', () async {
      expect(
          await verifyGoogleIdToken(
              'rác', ['123.apps.googleusercontent.com']),
          isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
    test('Facebook: thiếu app id/secret thì từ chối', () async {
      expect(await verifyFacebookToken('tok', '', ''), isNull);
      expect(await verifyFacebookToken('tok', '123', ''), isNull);
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
