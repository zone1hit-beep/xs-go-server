import 'package:test/test.dart';
import 'package:xs_go_server/apple_billing.dart';
import 'package:xs_go_server/db.dart';

class FakeAppleVerifier implements AppleVerifier {
  FakeAppleVerifier({this.transaction, this.notification});

  AppleVerifiedTransaction? transaction;
  AppleVerifiedNotification? notification;

  @override
  bool get configured => true;

  @override
  Future<AppleVerifiedTransaction> verifyAndReconcileTransaction(
          String signedTransaction) async =>
      transaction!;

  @override
  Future<AppleVerifiedNotification> verifyNotification(
          String signedPayload) async =>
      notification!;
}

AppleVerifiedTransaction tx({
  String productId = 'com.xsgo.xsGo.video.monthly',
  String transactionId = 'tx-1',
  String originalTransactionId = 'orig-1',
  String accountToken = '00000000-0000-4000-8000-000000000001',
  String status = 'active',
  int expiresAt = 9999999999999,
  bool serverApiReconciled = true,
}) =>
    AppleVerifiedTransaction(
      bundleId: 'com.xsgo.xsGo',
      environment: 'Sandbox',
      productId: productId,
      transactionId: transactionId,
      originalTransactionId: originalTransactionId,
      appAccountToken: accountToken,
      kind: productId.contains('.video.') ? 'subscription' : 'non_consumable',
      status: status,
      purchasedAt: 100,
      expiresAt: expiresAt,
      revokedAt: status == 'revoked' ? 200 : 0,
      transactionJwsVerified: true,
      serverApiReconciled: serverApiReconciled,
    );

void main() {
  test('Apple catalog allowlist map đủ đúng 20 sản phẩm', () {
    expect(AppleProductCatalog.products, hasLength(20));
    expect(AppleProductCatalog.entitlementOf('com.xsgo.xsGo.video.monthly'),
        'video_monthly');
    expect(AppleProductCatalog.entitlementOf('com.xsgo.xsGo.video.yearly'),
        'video_yearly');
    expect(AppleProductCatalog.entitlementOf('com.xsgo.xsGo.bjt.lifetime'),
        'bjt_lifetime');
    expect(
        AppleProductCatalog.entitlementOf('com.xsgo.xsGo.allaccess.lifetime'),
        'all_access_lifetime');
    for (final sector in const [
      'kaigo',
      'gaishoku',
      'inshoku',
      'kensetsu',
      'shukuhaku',
      'nogyo',
      'kogyo',
      'building',
      'jidosha',
      'gyogyo',
      'zosen',
      'koku',
      'unso',
      'tetsudo',
      'ringyo',
      'mokuzai',
    ]) {
      expect(
        AppleProductCatalog.entitlementOf('com.xsgo.xsGo.tokutei.$sector'),
        'tokutei_$sector',
      );
    }
    expect(AppleProductCatalog.entitlementOf('com.attacker.fake'), isNull);
  });

  test('production default verifier fail-closed', () async {
    final verifier = UnconfiguredAppleVerifier();
    expect(verifier.configured, isFalse);
    expect(
      verifier.verifyAndReconcileTransaction('client-jws'),
      throwsA(isA<AppleVerificationUnavailable>()),
    );
    expect(
      verifier.verifyNotification('notification-jws'),
      throwsA(isA<AppleVerificationUnavailable>()),
    );
  });

  group('AppleBillingService', () {
    late Db db;
    late int uid;
    late String accountToken;

    setUp(() {
      db = Db.open(':memory:');
      uid = db.createUser('apple@xsgo.app', 'x', 'vi', 'N5');
      accountToken = db.billingAccountToken(uid);
    });

    test('purchase chỉ grant sau JWS trust và App Store API reconciliation',
        () async {
      final fake =
          FakeAppleVerifier(transaction: tx(accountToken: accountToken));
      final service = AppleBillingService(db, fake);

      final result = await service.verifyPurchase(uid, 'signed-transaction');
      final duplicate =
          await service.verifyPurchase(uid, 'signed-transaction-again');

      expect(result.status, 'active');
      expect(duplicate.status, 'active');
      expect(db.storeTransactionsForUser(uid), hasLength(1));
      expect(db.userEntitlements(uid), contains('video_monthly'));
    });

    test('client JWS không reconciled qua App Store API bị từ chối', () async {
      final fake = FakeAppleVerifier(
          transaction:
              tx(accountToken: accountToken, serverApiReconciled: false));
      final service = AppleBillingService(db, fake);

      expect(
        service.verifyPurchase(uid, 'signed'),
        throwsA(isA<AppleEvidenceRejected>()),
      );
      expect(db.userEntitlements(uid), isEmpty);
    });

    test('bundle environment product và appAccountToken đều fail closed',
        () async {
      final cases = [
        tx(accountToken: '00000000-0000-4000-8000-000000000099'),
        tx(accountToken: accountToken, productId: 'com.attacker.fake'),
        tx(accountToken: accountToken).copyWith(bundleId: 'com.attacker.app'),
        tx(accountToken: accountToken).copyWith(environment: 'Unknown'),
      ];
      for (final evidence in cases) {
        final service =
            AppleBillingService(db, FakeAppleVerifier(transaction: evidence));
        expect(service.verifyPurchase(uid, 'signed'),
            throwsA(isA<AppleEvidenceRejected>()));
      }
      expect(db.userEntitlements(uid), isEmpty);
    });

    test('product type không được mâu thuẫn allowlist', () async {
      final evidence =
          tx(accountToken: accountToken).copyWith(kind: 'non_consumable');
      final service =
          AppleBillingService(db, FakeAppleVerifier(transaction: evidence));

      expect(service.verifyPurchase(uid, 'signed'),
          throwsA(isA<AppleEvidenceRejected>()));
      expect(db.userEntitlements(uid), isEmpty);
    });

    test('transaction đã bind account A bị account B từ chối', () async {
      final serviceA = AppleBillingService(
          db, FakeAppleVerifier(transaction: tx(accountToken: accountToken)));
      await serviceA.verifyPurchase(uid, 'signed');
      final uidB = db.createUser('b@xsgo.app', 'x', 'vi', 'N5');
      final tokenB = db.billingAccountToken(uidB);
      final serviceB = AppleBillingService(
          db, FakeAppleVerifier(transaction: tx(accountToken: tokenB)));

      expect(serviceB.verifyPurchase(uidB, 'signed'),
          throwsA(isA<AppleOwnershipConflict>()));
      expect(db.userEntitlements(uidB), isEmpty);
    });

    test('verified notification refund/revoke thu hồi lifetime idempotent',
        () async {
      final purchase = tx(
        productId: 'com.xsgo.xsGo.bjt.lifetime',
        accountToken: accountToken,
        expiresAt: 0,
      );
      await AppleBillingService(db, FakeAppleVerifier(transaction: purchase))
          .verifyPurchase(uid, 'signed');
      expect(db.userEntitlements(uid), contains('bjt_lifetime'));

      final revoked = tx(
        productId: 'com.xsgo.xsGo.bjt.lifetime',
        accountToken: accountToken,
        status: 'revoked',
        expiresAt: 0,
      );
      final notification = AppleVerifiedNotification(
        notificationId: 'notification-refund',
        notificationType: 'REFUND',
        bundleId: 'com.xsgo.xsGo',
        environment: 'Sandbox',
        outerJwsVerified: true,
        transactionJwsVerified: true,
        renewalInfoJwsVerified: false,
        transaction: revoked,
      );
      final service = AppleBillingService(
          db, FakeAppleVerifier(notification: notification));

      expect(await service.processNotification('outer-signed'), isTrue);
      expect(await service.processNotification('outer-signed'), isFalse);
      expect(db.userEntitlements(uid), isNot(contains('bjt_lifetime')));
    });

    test('subscription notification bắt buộc nested renewal JWS verified',
        () async {
      final active = tx(accountToken: accountToken);
      final notification = AppleVerifiedNotification(
        notificationId: 'notification-renew',
        notificationType: 'DID_RENEW',
        bundleId: 'com.xsgo.xsGo',
        environment: 'Sandbox',
        outerJwsVerified: true,
        transactionJwsVerified: true,
        renewalInfoJwsVerified: false,
        transaction: active,
      );
      final service = AppleBillingService(
          db, FakeAppleVerifier(notification: notification));

      expect(service.processNotification('outer'),
          throwsA(isA<AppleEvidenceRejected>()));
      expect(db.userEntitlements(uid), isEmpty);
    });

    test('notification sau delete account cập nhật ledger không hồi sinh grant',
        () async {
      final active = tx(accountToken: accountToken);
      await AppleBillingService(db, FakeAppleVerifier(transaction: active))
          .verifyPurchase(uid, 'signed');
      db.deleteUser(uid);

      final expired = active.copyWith(status: 'expired', expiresAt: 100);
      final notification = AppleVerifiedNotification(
        notificationId: 'notification-after-delete',
        notificationType: 'EXPIRED',
        bundleId: 'com.xsgo.xsGo',
        environment: 'Sandbox',
        outerJwsVerified: true,
        transactionJwsVerified: true,
        renewalInfoJwsVerified: true,
        transaction: expired,
      );
      final service = AppleBillingService(
          db, FakeAppleVerifier(notification: notification));

      expect(await service.processNotification('outer-after-delete'), isTrue);
      expect(await service.processNotification('outer-after-delete'), isFalse);
      final ledger = db.storeTransaction(
          store: 'apple', environment: 'Sandbox', transactionId: 'tx-1');
      expect(ledger!['user_id'], isNull);
      expect(ledger['status'], 'expired');
      expect(db.userEntitlements(uid), isEmpty);
    });
  });
}
