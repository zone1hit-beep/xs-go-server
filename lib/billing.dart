import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

/// ============================================================
///  GOOGLE PLAY BILLING — xác minh mua hàng phía SERVER
/// ============================================================
///
/// Nguyên tắc: app KHÔNG bao giờ tự cấp quyền chỉ vì client bảo "tôi đã mua".
/// Client gửi `purchaseToken` lên; server gọi Google Play Developer API để
/// xác minh rồi mới ghi entitlement vào DB. Không cấu hình được service
/// account thì TỪ CHỐI (không có chế độ "tin đại").
///
/// Cấu hình (env / Fly secrets):
///  - XSGO_GPLAY_SA_JSON : nội dung file JSON service account (khuyên dùng —
///    `fly secrets set XSGO_GPLAY_SA_JSON="$(cat sa.json)"`).
///  - XSGO_GPLAY_SA_FILE : (thay thế) đường dẫn tới file JSON.
///  - XSGO_ANDROID_PACKAGE : applicationId Android (mặc định com.xsgo.xs_go).
///
/// Service account tạo ở Google Cloud Console rồi CẤP QUYỀN trong Play Console
/// (Users & permissions → invite → quyền "View financial data" + "Manage
/// orders"). Xem GOOGLE_PLAY_RELEASE_CHECKLIST.md của app Flutter.

/// Kết quả xác minh một giao dịch.
class VerifiedPurchase {
  /// 'active' — đang có hiệu lực (đã thanh toán / sub còn hạn hoặc trong grace)
  /// 'pending' — chờ thanh toán (cửa hàng tiện lợi, chuyển khoản…)
  /// 'canceled' — đã hủy/hoàn tiền · 'expired' — sub hết hạn.
  final String state;

  /// Mốc hết hạn ms (subscription); 0 = không hết hạn (mua đứt).
  final int expiryMs;

  final String? orderId;

  /// true nếu Google báo giao dịch CHƯA acknowledge (cần ack trong 3 ngày,
  /// không thì Google tự hoàn tiền).
  final bool needsAck;

  const VerifiedPurchase(this.state, this.expiryMs, this.orderId,
      {this.needsAck = false});
}

class GooglePlayVerifier {
  GooglePlayVerifier(Map<String, String> env)
      : _packageName =
            env['XSGO_ANDROID_PACKAGE'] ?? 'com.xsgo.xs_go',
        _sa = _loadServiceAccount(env);

  final String _packageName;
  final Map<String, dynamic>? _sa;

  String? _accessToken;
  int _tokenExpMs = 0;

  /// Đã cấu hình service account chưa (chưa thì /billing trả 503).
  bool get enabled => _sa != null;

  String get packageName => _packageName;

  static Map<String, dynamic>? _loadServiceAccount(Map<String, String> env) {
    try {
      final raw = env['XSGO_GPLAY_SA_JSON'];
      if (raw != null && raw.trim().isNotEmpty) {
        return jsonDecode(raw) as Map<String, dynamic>;
      }
      final path = env['XSGO_GPLAY_SA_FILE'];
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return jsonDecode(File(path).readAsStringSync())
            as Map<String, dynamic>;
      }
    } catch (e) {
      stderr.writeln('[billing] service account JSON hỏng: $e');
    }
    return null;
  }

  /// OAuth2 access token của service account (cache ~50 phút).
  Future<String> _token() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && now < _tokenExpMs - 60000) {
      return _accessToken!;
    }
    final sa = _sa!;
    final jwt = JWT({
      'iss': sa['client_email'],
      'scope': 'https://www.googleapis.com/auth/androidpublisher',
      'aud': sa['token_uri'] ?? 'https://oauth2.googleapis.com/token',
      'iat': now ~/ 1000,
      'exp': now ~/ 1000 + 3600,
    });
    final assertion =
        jwt.sign(RSAPrivateKey(sa['private_key'] as String), algorithm: JWTAlgorithm.RS256);
    final resp = await http.post(
      Uri.parse(sa['token_uri'] as String? ??
          'https://oauth2.googleapis.com/token'),
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': assertion,
      },
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('OAuth Google lỗi ${resp.statusCode}: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    _accessToken = j['access_token'] as String;
    _tokenExpMs = now + ((j['expires_in'] as num? ?? 3600).toInt()) * 1000;
    return _accessToken!;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final t = await _token();
    final resp = await http.get(
      Uri.parse('https://androidpublisher.googleapis.com/androidpublisher/v3'
          '/applications/$_packageName$path'),
      headers: {'Authorization': 'Bearer $t'},
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 404 || resp.statusCode == 400) {
      // token/product không tồn tại → giao dịch giả hoặc gõ sai
      throw PurchaseNotFound('Google: ${resp.statusCode} ${resp.body}');
    }
    if (resp.statusCode != 200) {
      throw Exception('Google API ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> _post(String path) async {
    final t = await _token();
    final resp = await http.post(
      Uri.parse('https://androidpublisher.googleapis.com/androidpublisher/v3'
          '/applications/$_packageName$path'),
      headers: {'Authorization': 'Bearer $t'},
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      throw Exception('Google API ${resp.statusCode}: ${resp.body}');
    }
  }

  /// Xác minh SẢN PHẨM MUA ĐỨT (BJT, Tokutei, All Access).
  Future<VerifiedPurchase> verifyProduct(
      String productId, String token) async {
    final j = await _get('/purchases/products/$productId/tokens/$token');
    // purchaseState: 0 = purchased, 1 = canceled, 2 = pending
    final ps = (j['purchaseState'] as num?)?.toInt() ?? 1;
    final ack = (j['acknowledgementState'] as num?)?.toInt() ?? 0;
    final state = switch (ps) {
      0 => 'active',
      2 => 'pending',
      _ => 'canceled',
    };
    return VerifiedPurchase(state, 0, j['orderId'] as String?,
        needsAck: ps == 0 && ack == 0);
  }

  /// Acknowledge sản phẩm mua đứt (lưới an toàn khi client chưa kịp ack —
  /// Google TỰ HOÀN TIỀN sau 3 ngày nếu không ai acknowledge).
  Future<void> acknowledgeProduct(String productId, String token) =>
      _post('/purchases/products/$productId/tokens/$token:acknowledge');

  /// Xác minh SUBSCRIPTION (Video Premium tháng/năm) — API subscriptionsv2.
  Future<VerifiedPurchase> verifySubscription(String token) async {
    final j = await _get('/purchases/subscriptionsv2/tokens/$token');
    final state = j['subscriptionState'] as String? ?? '';
    final items = (j['lineItems'] as List?) ?? const [];
    var expiryMs = 0;
    for (final it in items) {
      final s = (it as Map)['expiryTime'] as String?;
      if (s != null) {
        final t = DateTime.tryParse(s)?.millisecondsSinceEpoch ?? 0;
        if (t > expiryMs) expiryMs = t;
      }
    }
    final orderId = j['latestOrderId'] as String?;
    // ACTIVE/IN_GRACE_PERIOD/CANCELED(còn hạn) đều cho dùng tới expiry.
    switch (state) {
      case 'SUBSCRIPTION_STATE_ACTIVE':
      case 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD':
      case 'SUBSCRIPTION_STATE_CANCELED': // hủy gia hạn nhưng CHƯA hết hạn
        final active =
            expiryMs > DateTime.now().millisecondsSinceEpoch;
        return VerifiedPurchase(
            active ? 'active' : 'expired', expiryMs, orderId,
            needsAck: (j['acknowledgementState'] as String?) ==
                'ACKNOWLEDGEMENT_STATE_PENDING');
      case 'SUBSCRIPTION_STATE_PENDING':
        return VerifiedPurchase('pending', expiryMs, orderId);
      case 'SUBSCRIPTION_STATE_ON_HOLD':
      case 'SUBSCRIPTION_STATE_PAUSED':
      case 'SUBSCRIPTION_STATE_EXPIRED':
        return VerifiedPurchase('expired', expiryMs, orderId);
      default:
        return VerifiedPurchase('canceled', expiryMs, orderId);
    }
  }

  /// Acknowledge subscription (endpoint v1 vẫn là cách chuẩn để ack).
  Future<void> acknowledgeSubscription(
          String subscriptionId, String token) =>
      _post('/purchases/subscriptions/$subscriptionId/tokens/$token'
          ':acknowledge');
}

/// Token không tồn tại / giao dịch giả.
class PurchaseNotFound implements Exception {
  final String message;
  PurchaseNotFound(this.message);
  @override
  String toString() => message;
}

/// ============================================================
///  DANH MỤC SẢN PHẨM (bản server — phải khớp client product_catalog.dart)
/// ============================================================
class BillingCatalog {
  BillingCatalog(Map<String, String> env)
      : videoMonthly =
            env['XSGO_SKU_VIDEO_MONTHLY'] ?? 'xsgo_video_premium_monthly',
        videoYearly =
            env['XSGO_SKU_VIDEO_YEARLY'] ?? 'xsgo_video_premium_yearly',
        bjt = env['XSGO_SKU_BJT'] ?? 'xsgo_bjt_lifetime',
        allAccess = env['XSGO_SKU_ALL_ACCESS'] ?? 'xsgo_all_access_lifetime',
        tokuteiPrefix = env['XSGO_SKU_TOKUTEI_PREFIX'] ?? 'xsgo_tokutei_';

  final String videoMonthly;
  final String videoYearly;
  final String bjt;
  final String allAccess;
  final String tokuteiPrefix;

  bool isSubscription(String productId) =>
      productId == videoMonthly || productId == videoYearly;

  /// Product ID → entitlement key. null = không nhận ra (từ chối).
  String? entitlementOf(String productId) {
    if (productId == videoMonthly) return 'video_monthly';
    if (productId == videoYearly) return 'video_yearly';
    if (productId == bjt) return 'bjt_lifetime';
    if (productId == allAccess) return 'all_access_lifetime';
    if (productId.startsWith(tokuteiPrefix)) {
      final industry = productId.substring(tokuteiPrefix.length);
      if (industry.isNotEmpty &&
          RegExp(r'^[a-z0-9_]+$').hasMatch(industry)) {
        return 'tokutei_$industry';
      }
    }
    return null;
  }
}

/// Các entitlement cho phép XEM VIDEO KHÔNG GIỚI HẠN + nhập video riêng.
const kVideoEntitlements = {
  'video_monthly',
  'video_yearly',
  'all_access_lifetime',
};

bool hasVideoPremium(Iterable<String> owned) =>
    owned.any(kVideoEntitlements.contains);
