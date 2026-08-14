import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/ai.dart';
import 'package:xs_go_server/api.dart';
import 'package:xs_go_server/apple_billing.dart';
import 'package:xs_go_server/apple_verifier_http.dart';
import 'package:xs_go_server/asr.dart';
import 'package:xs_go_server/db.dart';
import 'package:xs_go_server/security.dart';

class RouteAppleVerifier implements AppleVerifier {
  RouteAppleVerifier(
      {this.transaction, this.notification, this.notificationError});
  AppleVerifiedTransaction? transaction;
  AppleVerifiedNotification? notification;
  Object? notificationError;

  @override
  bool get configured => true;

  @override
  Future<AppleVerifiedTransaction> verifyAndReconcileTransaction(
          String signedTransaction) async =>
      transaction!;

  @override
  Future<AppleVerifiedNotification> verifyNotification(
      String signedPayload) async {
    if (notificationError case final error?) throw error;
    return notification!;
  }
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
      signedDate: 100,
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
          {String? token, Object? body, String? rawBody, String? ip}) =>
      Future.sync(() => api(Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: {
              if (token != null) 'authorization': 'Bearer $token',
              if (body != null) 'content-type': 'application/json',
              if (rawBody != null) 'content-type': 'application/json',
              if (ip != null) 'fly-client-ip': ip,
            },
            body: rawBody ?? (body == null ? null : jsonEncode(body)),
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

  test('sidecar unavailable trả Apple 503 nhưng Dart health vẫn phục vụ',
      () async {
    final verifier = appleVerifierFromEnvironment(
      const {
        'APPLE_IAP_KEY_PATH': '/runtime/apple.p8',
        'APPLE_IAP_KEY_ID': 'KEY1234567',
        'APPLE_IAP_ISSUER_ID':
            '11111111-2222-3333-4444-555555555555',
        'APPLE_BUNDLE_ID': 'com.xsgo.xsGo',
        'APPLE_APP_ID': '6800309856',
        'APPLE_ENVIRONMENT': 'SANDBOX',
        'XSGO_APPLE_VERIFIER_TOKEN':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
      baseUri: Uri.parse('http://127.0.0.1:1'),
      timeout: const Duration(milliseconds: 100),
    );
    final api = buildRouter(db, Ai(), Asr(), appleVerifier: verifier).call;

    final verify = await request(api, 'POST', '/billing/apple/verify',
        token: jwt, body: {'signedTransaction': 'client-jws'});
    final health = await request(api, 'GET', '/health');

    expect(verify.statusCode, 503);
    expect(health.statusCode, 200);
    expect(db.userEntitlements(uid), isEmpty);
  });

  test(
      'Apple verify trusted adapter grant idempotent và không tin product client',
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
        signedDate: 100,
        outerJwsVerified: true,
        transactionJwsVerified: true,
        renewalInfoJwsVerified: true,
        transaction: tx,
      ),
    );
    final api = buildRouter(db, Ai(), Asr(), appleVerifier: verifier).call;
    final first = await request(api, 'POST', '/billing/apple/notifications/v2',
        body: {'signedPayload': 'outer-signed'});
    final second = await request(api, 'POST', '/billing/apple/notifications/v2',
        body: {'signedPayload': 'outer-signed'});
    expect(first.statusCode, 200);
    expect(second.statusCode, 200);
    expect(
        (jsonDecode(await first.readAsString()) as Map)['processed'], isTrue);
    expect(
        (jsonDecode(await second.readAsString()) as Map)['processed'], isFalse);
  });

  test('Notifications V2 ACK payload malformed/unverifiable vĩnh viễn',
      () async {
    final malformedApi = buildRouter(db, Ai(), Asr(),
            appleVerifier: RouteAppleVerifier(
                notificationError: const AppleEvidenceRejected('bad jws')))
        .call;

    final malformed = await request(
        malformedApi, 'POST', '/billing/apple/notifications/v2',
        rawBody: '{not-json', ip: '198.51.100.10');
    expect(malformed.statusCode, 200);
    expect((jsonDecode(await malformed.readAsString()) as Map)['discarded'],
        isTrue);

    final unverifiable = await request(
        malformedApi, 'POST', '/billing/apple/notifications/v2',
        body: {'signedPayload': 'permanent-bad-jws'}, ip: '198.51.100.10');
    expect(unverifiable.statusCode, 200);
    expect((jsonDecode(await unverifiable.readAsString()) as Map)['discarded'],
        isTrue);
  });

  test('Notifications V2 body quá giới hạn được ACK và không vào verifier',
      () async {
    final verifier = RouteAppleVerifier(
        notificationError: StateError('verifier must not be called'));
    final api = buildRouter(db, Ai(), Asr(), appleVerifier: verifier).call;
    final response = await request(
        api, 'POST', '/billing/apple/notifications/v2',
        rawBody: jsonEncode({'signedPayload': 'x' * (384 * 1024)}),
        ip: '198.51.100.11');

    expect(response.statusCode, 200);
    expect((jsonDecode(await response.readAsString()) as Map)['reason'],
        'body_too_large');
  });

  test('Notifications V2 verifier/runtime transient trả 503 để Apple retry',
      () async {
    for (final error in <Object>[
      const AppleVerificationUnavailable(),
      StateError('trust runtime temporarily unavailable'),
    ]) {
      final api = buildRouter(db, Ai(), Asr(),
              appleVerifier: RouteAppleVerifier(notificationError: error))
          .call;
      final response = await request(
          api, 'POST', '/billing/apple/notifications/v2',
          body: {'signedPayload': 'valid-shape'}, ip: '198.51.100.12');
      expect(response.statusCode, 503);
    }
  });
}
