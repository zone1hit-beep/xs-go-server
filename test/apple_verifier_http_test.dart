import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/apple_billing.dart';
import 'package:xs_go_server/apple_verifier_http.dart';
import 'package:xs_go_server/db.dart';

const completeEnv = <String, String>{
  'APPLE_IAP_KEY_PATH': '/outside/repo/key.p8',
  'APPLE_IAP_KEY_ID': 'KEY1234567',
  'APPLE_IAP_ISSUER_ID': '11111111-2222-3333-4444-555555555555',
  'APPLE_BUNDLE_ID': 'com.xsgo.xsGo',
  'APPLE_APP_ID': '6800309856',
  'APPLE_ENVIRONMENT': 'SANDBOX',
  'XSGO_APPLE_VERIFIER_TOKEN':
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
};

Map<String, dynamic> evidence({
  String transactionId = 'tx-1',
  String productId = 'com.xsgo.xsGo.video.monthly',
  String accountToken = '00000000-0000-4000-8000-000000000001',
  bool reconciled = false,
}) =>
    {
      'bundleId': 'com.xsgo.xsGo',
      'environment': 'Sandbox',
      'productId': productId,
      'transactionId': transactionId,
      'originalTransactionId': 'orig-1',
      'appAccountToken': accountToken,
      'kind': 'subscription',
      'status': 'active',
      'signedDate': 200,
      'purchasedAt': 100,
      'expiresAt': 9999999999999,
      'revokedAt': 0,
      'transactionJwsVerified': true,
      'serverApiReconciled': reconciled,
    };

void main() {
  test('missing or partial config leaves the existing fail-closed verifier',
      () async {
    for (final env in [
      <String, String>{},
      {'APPLE_IAP_KEY_ID': 'only-one'}
    ]) {
      final verifier = appleVerifierFromEnvironment(env);
      expect(verifier.configured, isFalse);
      expect(verifier.verifyAndReconcileTransaction('jws'),
          throwsA(isA<AppleVerificationUnavailable>()));
    }
  });

  test('verified device evidence is reconciled and identity-matched', () async {
    final requests = <http.Request>[];
    final verifier = appleVerifierFromEnvironment(
      completeEnv,
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/verify/transaction') {
          return http.Response(jsonEncode(evidence()), 200);
        }
        if (request.url.path == '/transaction/info') {
          return http.Response(jsonEncode(evidence(reconciled: true)), 200);
        }
        return http.Response('', 404);
      }),
    );

    final result = await verifier.verifyAndReconcileTransaction('device-jws');

    expect(result.transactionId, 'tx-1');
    expect(result.serverApiReconciled, isTrue);
    expect(requests.map((request) => request.url.path), [
      '/verify/transaction',
      '/transaction/info',
    ]);
    for (final request in requests) {
      expect(request.headers['authorization'],
          'Bearer ${completeEnv['XSGO_APPLE_VERIFIER_TOKEN']}');
    }
    expect(
        jsonDecode(requests.first.body), {'signedTransaction': 'device-jws'});
    expect(jsonDecode(requests.last.body), {'transactionId': 'tx-1'});
  });

  test('authoritative transaction identity mismatch is rejected', () async {
    final verifier = appleVerifierFromEnvironment(
      completeEnv,
      client: MockClient((request) async => http.Response(
            jsonEncode(request.url.path == '/verify/transaction'
                ? evidence()
                : evidence(transactionId: 'different', reconciled: true)),
            200,
          )),
    );

    expect(verifier.verifyAndReconcileTransaction('device-jws'),
        throwsA(isA<AppleEvidenceRejected>()));
  });

  test(
      'valid mocked sidecar evidence reaches ledger, wrong account/product do not',
      () async {
    final db = Db.open(':memory:');
    final uid = db.createUser('sidecar@xsgo.app', 'x', 'vi', 'N5');
    final accountToken = db.billingAccountToken(uid);

    AppleVerifier verifierFor(Map<String, dynamic> first) =>
        appleVerifierFromEnvironment(
          completeEnv,
          client: MockClient((request) async => http.Response(
                jsonEncode(request.url.path == '/verify/transaction'
                    ? first
                    : {...first, 'serverApiReconciled': true}),
                200,
              )),
        );

    final valid = verifierFor(evidence(accountToken: accountToken));
    await AppleBillingService(db, valid).verifyPurchase(uid, 'device-jws');
    expect(db.userEntitlements(uid), contains('video_monthly'));

    for (final bad in [
      evidence(accountToken: '00000000-0000-4000-8000-000000000099'),
      evidence(accountToken: accountToken, productId: 'com.attacker.fake'),
    ]) {
      final otherDb = Db.open(':memory:');
      final otherUid = otherDb.createUser('bad@xsgo.app', 'x', 'vi', 'N5');
      expect(
        AppleBillingService(otherDb, verifierFor(bad))
            .verifyPurchase(otherUid, 'device-jws'),
        throwsA(isA<AppleEvidenceRejected>()),
      );
      expect(otherDb.userEntitlements(otherUid), isEmpty);
    }
  });

  test('sidecar timeout and unavailable socket fail closed', () async {
    final timeoutVerifier = appleVerifierFromEnvironment(
      completeEnv,
      timeout: const Duration(milliseconds: 10),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    expect(timeoutVerifier.verifyAndReconcileTransaction('device-jws'),
        throwsA(isA<AppleVerificationUnavailable>()));

    final unavailableVerifier = appleVerifierFromEnvironment(
      completeEnv,
      timeout: const Duration(milliseconds: 100),
      baseUri: Uri.parse('http://127.0.0.1:1'),
    );
    expect(unavailableVerifier.verifyAndReconcileTransaction('device-jws'),
        throwsA(isA<AppleVerificationUnavailable>()));
  });

  test(
      'permanent evidence rejection stays distinct from malformed trusted response',
      () async {
    final rejected = appleVerifierFromEnvironment(
      completeEnv,
      client: MockClient((_) async =>
          http.Response(jsonEncode({'error': 'evidence_rejected'}), 422)),
    );
    expect(rejected.verifyAndReconcileTransaction('bad-jws'),
        throwsA(isA<AppleEvidenceRejected>()));

    final malformed = appleVerifierFromEnvironment(
      completeEnv,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(malformed.verifyAndReconcileTransaction('jws'),
        throwsA(isA<AppleVerificationUnavailable>()));
  });
}
