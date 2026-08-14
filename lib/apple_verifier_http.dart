import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'apple_billing.dart';

const _requiredConfig = {
  'APPLE_IAP_KEY_PATH',
  'APPLE_IAP_KEY_ID',
  'APPLE_IAP_ISSUER_ID',
  'APPLE_BUNDLE_ID',
  'APPLE_APP_ID',
  'APPLE_ENVIRONMENT',
  'XSGO_APPLE_VERIFIER_TOKEN',
};

AppleVerifier appleVerifierFromEnvironment(
  Map<String, String> environment, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 12),
  Uri? baseUri,
}) {
  final complete = _requiredConfig.every(
      (key) => (environment[key] ?? '').trim().isNotEmpty);
  final target = (environment['APPLE_ENVIRONMENT'] ?? '').trim();
  final token = (environment['XSGO_APPLE_VERIFIER_TOKEN'] ?? '').trim();
  if (!complete ||
      (target != 'SANDBOX' && target != 'PRODUCTION') ||
      token.length < 32) {
    return UnconfiguredAppleVerifier();
  }
  return HttpAppleVerifier(
    client: client ?? http.Client(),
    baseUri: baseUri ?? Uri.parse('http://127.0.0.1:9000'),
    token: token,
    timeout: timeout,
  );
}

class HttpAppleVerifier implements AppleVerifier {
  HttpAppleVerifier({
    required http.Client client,
    required Uri baseUri,
    required String token,
    required Duration timeout,
  })  : _client = client,
        _baseUri = baseUri,
        _token = token,
        _timeout = timeout;

  final http.Client _client;
  final Uri _baseUri;
  final String _token;
  final Duration _timeout;

  @override
  bool get configured => true;

  @override
  Future<AppleVerifiedTransaction> verifyAndReconcileTransaction(
      String signedTransaction) async {
    final device = _transactionFromJson(await _post(
      '/verify/transaction',
      {'signedTransaction': signedTransaction},
    ));
    final authoritative = _transactionFromJson(await _post(
      '/transaction/info',
      {'transactionId': device.transactionId},
    ));
    if (!_sameIdentity(device, authoritative) ||
        !authoritative.serverApiReconciled) {
      throw const AppleEvidenceRejected(
          'Apple authoritative transaction không khớp');
    }
    return authoritative;
  }

  @override
  Future<AppleVerifiedNotification> verifyNotification(
      String signedPayload) async {
    final json = await _post(
      '/verify/notification',
      {'signedPayload': signedPayload},
    );
    final transactionJson = json['transaction'];
    if (transactionJson is! Map<String, dynamic>) {
      throw const AppleVerificationUnavailable();
    }
    try {
      return AppleVerifiedNotification(
        notificationId: _string(json, 'notificationId'),
        notificationType: _string(json, 'notificationType'),
        bundleId: _string(json, 'bundleId'),
        environment: _string(json, 'environment'),
        signedDate: _integer(json, 'signedDate'),
        outerJwsVerified: _boolean(json, 'outerJwsVerified'),
        transactionJwsVerified:
            _boolean(json, 'transactionJwsVerified'),
        renewalInfoJwsVerified:
            _boolean(json, 'renewalInfoJwsVerified'),
        transaction: _transactionFromJson(transactionJson),
      );
    } on FormatException {
      throw const AppleVerificationUnavailable();
    }
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    try {
      final response = await _client
          .post(
            _baseUri.resolve(path),
            headers: {
              'authorization': 'Bearer $_token',
              'content-type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (response.statusCode == 400 ||
          response.statusCode == 404 ||
          response.statusCode == 413 ||
          response.statusCode == 422) {
        throw const AppleEvidenceRejected('Apple evidence bị từ chối');
      }
      if (response.statusCode != 200) {
        throw const AppleVerificationUnavailable();
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Sidecar response must be an object');
      }
      return decoded;
    } on AppleEvidenceRejected {
      rethrow;
    } on AppleVerificationUnavailable {
      rethrow;
    } on TimeoutException {
      throw const AppleVerificationUnavailable();
    } on Object {
      throw const AppleVerificationUnavailable();
    }
  }

  AppleVerifiedTransaction _transactionFromJson(Map<String, dynamic> json) {
    try {
      return AppleVerifiedTransaction(
        bundleId: _string(json, 'bundleId'),
        environment: _string(json, 'environment'),
        productId: _string(json, 'productId'),
        transactionId: _string(json, 'transactionId'),
        originalTransactionId: _string(json, 'originalTransactionId'),
        appAccountToken: _string(json, 'appAccountToken'),
        kind: _string(json, 'kind'),
        status: _string(json, 'status'),
        signedDate: _integer(json, 'signedDate'),
        purchasedAt: _integer(json, 'purchasedAt'),
        expiresAt: _integer(json, 'expiresAt', positive: false),
        revokedAt: _integer(json, 'revokedAt', positive: false),
        transactionJwsVerified:
            _boolean(json, 'transactionJwsVerified'),
        serverApiReconciled: _boolean(json, 'serverApiReconciled'),
      );
    } on FormatException {
      throw const AppleVerificationUnavailable();
    }
  }

  static bool _sameIdentity(
      AppleVerifiedTransaction a, AppleVerifiedTransaction b) {
    return a.bundleId == b.bundleId &&
        a.environment == b.environment &&
        a.productId == b.productId &&
        a.transactionId == b.transactionId &&
        a.originalTransactionId == b.originalTransactionId &&
        a.appAccountToken == b.appAccountToken &&
        a.kind == b.kind;
  }

  static String _string(Map<String, dynamic> json, String key) {
    final result = json[key];
    if (result is! String || result.trim().isEmpty) {
      throw FormatException('Missing $key');
    }
    return result;
  }

  static int _integer(Map<String, dynamic> json, String key,
      {bool positive = true}) {
    final result = json[key];
    if (result is! int || (positive ? result <= 0 : result < 0)) {
      throw FormatException('Invalid $key');
    }
    return result;
  }

  static bool _boolean(Map<String, dynamic> json, String key) {
    final result = json[key];
    if (result is! bool) throw FormatException('Invalid $key');
    return result;
  }
}
