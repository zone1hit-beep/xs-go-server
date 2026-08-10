import 'package:test/test.dart';
import 'package:xs_go_server/billing.dart';
import 'package:xs_go_server/db.dart';

void main() {
  group('BillingCatalog: Product ID → entitlement', () {
    final c = BillingCatalog(const {});

    test('các sản phẩm cố định map đúng key granular', () {
      expect(c.entitlementOf('xsgo_video_premium_monthly'), 'video_monthly');
      expect(c.entitlementOf('xsgo_video_premium_yearly'), 'video_yearly');
      expect(c.entitlementOf('xsgo_bjt_lifetime'), 'bjt_lifetime');
      expect(
          c.entitlementOf('xsgo_all_access_lifetime'), 'all_access_lifetime');
    });

    test('Tokutei suy theo tiền tố — thêm ngành mới không cần sửa code', () {
      expect(c.entitlementOf('xsgo_tokutei_kaigo'), 'tokutei_kaigo');
      expect(c.entitlementOf('xsgo_tokutei_nganh_moi_2027'),
          'tokutei_nganh_moi_2027');
    });

    test('sản phẩm lạ / tiêm ký tự bẩn bị từ chối', () {
      expect(c.entitlementOf('com.hacker.free'), isNull);
      expect(c.entitlementOf('xsgo_tokutei_'), isNull);
      expect(c.entitlementOf("xsgo_tokutei_kaigo'; DROP TABLE"), isNull);
    });

    test('phân loại subscription đúng', () {
      expect(c.isSubscription('xsgo_video_premium_monthly'), isTrue);
      expect(c.isSubscription('xsgo_video_premium_yearly'), isTrue);
      expect(c.isSubscription('xsgo_bjt_lifetime'), isFalse);
      expect(c.isSubscription('xsgo_tokutei_kaigo'), isFalse);
    });

    test('env override đổi được Product ID mà không đổi entitlement', () {
      final c2 = BillingCatalog(const {
        'XSGO_SKU_BJT': 'bjt_v2_launch',
        'XSGO_SKU_TOKUTEI_PREFIX': 'tk_',
      });
      expect(c2.entitlementOf('bjt_v2_launch'), 'bjt_lifetime');
      expect(c2.entitlementOf('tk_kaigo'), 'tokutei_kaigo');
      expect(c2.entitlementOf('xsgo_bjt_lifetime'), isNull);
    });
  });

  group('hasVideoPremium', () {
    test('chỉ video/all-access mở video không giới hạn', () {
      expect(hasVideoPremium(['video_monthly']), isTrue);
      expect(hasVideoPremium(['video_yearly']), isTrue);
      expect(hasVideoPremium(['all_access_lifetime']), isTrue);
      // Mua BJT/Tokutei KHÔNG kéo theo video premium (spec giá 10/8).
      expect(hasVideoPremium(['bjt_lifetime', 'tokutei_kaigo']), isFalse);
      expect(hasVideoPremium([]), isFalse);
    });
  });

  group('Db entitlements: hết hạn + quota', () {
    late Db db;
    late int uid;

    setUp(() {
      db = Db.open(':memory:');
      uid = db.createUser('test@xsgo.app', 'x', 'vi', 'N5');
    });

    test('quyền trọn đời (expires 0) không bao giờ rơi', () {
      db.grantEntitlement(uid, 'bjt_lifetime', source: 'google_play');
      expect(db.userEntitlements(uid), contains('bjt_lifetime'));
    });

    test('subscription hết hạn tự rơi khỏi danh sách quyền', () {
      final past = DateTime.now().millisecondsSinceEpoch - 1000;
      final future = DateTime.now().millisecondsSinceEpoch + 86400000;
      db.grantEntitlement(uid, 'video_monthly',
          expiresAt: past, source: 'google_play');
      expect(db.userEntitlements(uid), isNot(contains('video_monthly')));
      // Gia hạn (đẩy mốc mới) → quyền sống lại — INSERT OR UPDATE giữ 1 dòng.
      db.grantEntitlement(uid, 'video_monthly',
          expiresAt: future, source: 'google_play');
      expect(db.userEntitlements(uid), contains('video_monthly'));
    });

    test('purchase token gắn chặt user đầu tiên', () {
      db.upsertPurchase(
          token: 'tok_1',
          userId: uid,
          productId: 'xsgo_bjt_lifetime',
          kind: 'inapp',
          state: 'active');
      final p = db.purchaseByToken('tok_1');
      expect(p!['user_id'], uid);
      // update giữ nguyên chủ (route verify từ chối user khác TRƯỚC khi ghi).
      db.upsertPurchase(
          token: 'tok_1',
          userId: uid,
          productId: 'xsgo_bjt_lifetime',
          kind: 'inapp',
          state: 'canceled');
      expect(db.purchaseByToken('tok_1')!['state'], 'canceled');
    });

    test('quota video: cộng dồn theo tháng, import đếm theo ngày', () {
      db.addVideoUsage(uid, 'V:2026-08', 120);
      db.addVideoUsage(uid, 'V:2026-08', 60);
      expect(db.videoUsedSec(uid, 'V:2026-08'), 180);
      expect(db.videoUsedSec(uid, 'V:2026-09'), 0); // sang tháng tự reset

      db.addImport(uid, '2026-08-10');
      db.addImport(uid, '2026-08-10');
      expect(db.importCount(uid, '2026-08-10'), 2);
      expect(db.importCount(uid, '2026-08-11'), 0); // sang ngày tự reset
    });
  });
}
