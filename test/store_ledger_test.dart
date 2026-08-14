import 'package:test/test.dart';
import 'package:xs_go_server/db.dart';

void main() {
  late Db db;
  late int accountA;
  late int accountB;

  setUp(() {
    db = Db.open(':memory:');
    accountA = db.createUser('a@xsgo.app', 'x', 'vi', 'N5');
    accountB = db.createUser('b@xsgo.app', 'x', 'vi', 'N5');
  });

  test('billing account token là UUID v4 ổn định và riêng từng account', () {
    final a1 = db.billingAccountToken(accountA);
    final a2 = db.billingAccountToken(accountA);
    final b = db.billingAccountToken(accountB);

    expect(a1, a2);
    expect(a1, isNot(b));
    expect(
      a1,
      matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
  });

  test('transaction upsert idempotent nhưng không đổi owner hoặc product', () {
    final token = db.billingAccountToken(accountA);
    db.upsertStoreTransaction(
      store: 'apple',
      environment: 'Sandbox',
      transactionId: 'tx-1',
      originalTransactionId: 'orig-1',
      userId: accountA,
      accountToken: token,
      productId: 'com.xsgo.xsGo.bjt.lifetime',
      entitlementKey: 'bjt_lifetime',
      kind: 'non_consumable',
      status: 'active',
      purchasedAt: 100,
    );
    db.upsertStoreTransaction(
      store: 'apple',
      environment: 'Sandbox',
      transactionId: 'tx-1',
      originalTransactionId: 'orig-1',
      userId: accountA,
      accountToken: token,
      productId: 'com.xsgo.xsGo.bjt.lifetime',
      entitlementKey: 'bjt_lifetime',
      kind: 'non_consumable',
      status: 'active',
      purchasedAt: 100,
    );

    expect(db.storeTransactionsForUser(accountA), hasLength(1));
    expect(
      () => db.upsertStoreTransaction(
        store: 'apple',
        environment: 'Sandbox',
        transactionId: 'tx-1',
        originalTransactionId: 'orig-1',
        userId: accountB,
        accountToken: db.billingAccountToken(accountB),
        productId: 'com.xsgo.xsGo.allaccess.lifetime',
        entitlementKey: 'all_access_lifetime',
        kind: 'non_consumable',
        status: 'active',
        purchasedAt: 100,
      ),
      throwsStateError,
    );
  });

  test('store grants hết hạn hoặc revoke nhưng không xoá admin grant', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.grantEntitlement(accountA, 'video_monthly', source: 'admin');
    db.upsertStoreEntitlementGrant(
      store: 'apple',
      environment: 'Sandbox',
      transactionId: 'tx-sub',
      userId: accountA,
      entitlementKey: 'video_monthly',
      status: 'revoked',
      expiresAt: now - 1,
    );

    expect(db.userEntitlements(accountA), contains('video_monthly'));
  });

  test('hai store cùng entitlement: revoke Apple không làm mất Google', () {
    final future = DateTime.now().millisecondsSinceEpoch + 86400000;
    db.upsertStoreEntitlementGrant(
      store: 'google_play',
      environment: 'Production',
      transactionId: 'g-1',
      userId: accountA,
      entitlementKey: 'video_yearly',
      status: 'active',
      expiresAt: future,
    );
    db.upsertStoreEntitlementGrant(
      store: 'apple',
      environment: 'Sandbox',
      transactionId: 'a-1',
      userId: accountA,
      entitlementKey: 'video_yearly',
      status: 'revoked',
      expiresAt: future,
    );

    expect(db.userEntitlements(accountA), contains('video_yearly'));
  });

  test('delete account xoá PII/grant nhưng giữ ledger để reconciliation', () {
    final token = db.billingAccountToken(accountA);
    db.upsertStoreTransaction(
      store: 'apple',
      environment: 'Production',
      transactionId: 'tx-delete',
      originalTransactionId: 'orig-delete',
      userId: accountA,
      accountToken: token,
      productId: 'com.xsgo.xsGo.video.monthly',
      entitlementKey: 'video_monthly',
      kind: 'subscription',
      status: 'active',
      purchasedAt: 100,
      expiresAt: 9999999999999,
    );
    db.upsertStoreEntitlementGrant(
      store: 'apple',
      environment: 'Production',
      transactionId: 'tx-delete',
      userId: accountA,
      entitlementKey: 'video_monthly',
      status: 'active',
      expiresAt: 9999999999999,
    );
    expect(db.hasActiveStoreSubscription(accountA), isTrue);

    db.deleteUser(accountA);

    final row = db.storeTransaction(
        store: 'apple', environment: 'Production', transactionId: 'tx-delete');
    expect(row, isNotNull);
    expect(row!['user_id'], isNull);
    expect(row['account_token'], token);
    expect(db.userEntitlements(accountA), isEmpty);
  });

  test('event inbox chỉ process một event đã complete', () {
    expect(
      db.beginStoreEvent(
        store: 'apple',
        environment: 'Sandbox',
        eventId: 'notification-1',
        eventType: 'DID_RENEW',
        payloadHash: 'hash',
        signedPayload: 'signed',
      ),
      isTrue,
    );
    db.completeStoreEvent(
        store: 'apple', environment: 'Sandbox', eventId: 'notification-1');
    expect(
      db.beginStoreEvent(
        store: 'apple',
        environment: 'Sandbox',
        eventId: 'notification-1',
        eventType: 'DID_RENEW',
        payloadHash: 'hash',
        signedPayload: 'signed',
      ),
      isFalse,
    );
  });
}
