import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/ai.dart';
import 'package:xs_go_server/api.dart';
import 'package:xs_go_server/apple_billing.dart';
import 'package:xs_go_server/asr.dart';
import 'package:xs_go_server/db.dart';
import 'package:xs_go_server/security.dart';

class RouteAppleVerifier implements AppleVerifier {
  RouteAppleVerifier({this.transaction, this.notification});
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

AppleVerifiedTransaction verifiedTx(String accountToken,
        {String status = 'active'}) =>
    AppleVerifiedTransaction(
      bundleId: 'com.xsgo.xsGo',
      environment: 'Sandbox',
      productId: 'com.xsgo.xsGo.video.monthly',
      transactionId: 'api-tx-1',
      originalTransactionId: 'api-orig-1',
      appAccountToken: accountToken,
      kind: 'subscription',
      status: status,
      purchasedAt: 100,
      expiresAt: 9999999999999,
      revokedAt: 0,
      transactionJwsVerified: true,
      serverApiReconciled: true,
    );

void main() {
  late Db db;
  late int uid;
  late String jwt;

  setUp(() {
    db = Db.open(':memory:');
    uid = db.createUser('iap@xsgo.app', 'x', 'vi', 'N5');
    jwt = signJwt({'sub': uid, 'email': 'iap@xsgo.app'});
  });

  Future<Response> request(Handler api, String method, String path,
          {String? token, Object? body}) =>
      Future.sync(() => api(Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: {
              if (token != null) 'authorization': 'Bearer $token',
              if (body != null) 'content-type': 'application/json',
            },
            body: body == null ? null : jsonEncode(body),
          )));

  test('billing context yêu cầu auth và trả UUID ổn định', () async {
    final api = buildRouter(db, Ai(), Asr()).call;
    expect((await request(api, 'GET', '/me/billing-context')).statusCode, 401);
    final first = await request(api, 'GET', '/me/billing-context', token: jwt);
    final second = await request(api, 'GET', '/me/billing-context', token: jwt);
    final a = jsonDecode(await first.readAsString()) as Map<String, dynamic>;
    final b = jsonDecode(await second.readAsString()) as Map<String, dynamic>;
    expect(a['appAccountToken'], b['appAccountToken']);
    expect(a['activeSubscription'], isFalse);
  });

  test('Apple verify production default trả 503 và không grant', () async {
    final api = buildRouter(db, Ai(), Asr()).call;
    final response = await request(api, 'POST', '/billing/apple/verify',
        token: jwt, body: {'signedTransaction': 'client-jws'});
    expect(response.statusCode, 503);
    expect(db.userEntitlements(uid), isEmpty);
  });

  test('Apple verify trusted adapter grant idempotent và không tin product client',
      () async {
    final token = db.billingAccountToken(uid);
    final verifier = RouteAppleVerifier(transaction: verifiedTx(token));
    final api = buildRouter(db, Ai(), Asr(), appleVerifier: verifier).call;
    for (var i = 0; i < 2; i++) {
      final response = await request(api, 'POST', '/billing/apple/verify',
          token: jwt,
          body: {
            'signedTransaction': 'signed-evidence',
            'productId': 'com.attacker.fake'
          });
      expect(response.statusCode, 200);
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['status'], 'active');
      expect(json['owned'], contains('video_monthly'));
    }
    expect(db.storeTransactionsForUser(uid), hasLength(1));
  });

  test('Notifications V2 xử lý outer+nested verified đúng một lần', () async {
    final token = db.billingAccountToken(uid);
    final tx = verifiedTx(token);
    final verifier = RouteAppleVerifier(
      transaction: tx,
      notification: AppleVerifiedNotification(
        notificationId: 'api-notification-1',
        notificationType: 'DID_RENEW',
        bundleId: 'com.xsgo.xsGo',
        environment: 'Sandbox',
        outerJwsVerified: true,
        transactionJwsVerified: true,
        renewalInfoJwsVerified: true,
        transaction: tx,
      ),
    );
    final api = buildRouter(db, Ai(), Asr(), appleVerifier: verifier).call;
    final first = await request(
        api, 'POST', '/billing/apple/notifications/v2',
        body: {'signedPayload': 'outer-signed'});
    final second = await request(
        api, 'POST', '/billing/apple/notifications/v2',
        body: {'signedPayload': 'outer-signed'});
    expect(first.statusCode, 200);
    expect(second.statusCode, 200);
    expect((jsonDecode(await first.readAsString()) as Map)['processed'], isTrue);
    expect(
        (jsonDecode(await second.readAsString()) as Map)['processed'], isFalse);
  });
}
