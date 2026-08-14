import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'db.dart';

class AppleVerificationUnavailable implements Exception {
  const AppleVerificationUnavailable();
  @override
  String toString() => 'Apple verifier chưa được cấu hình';
}

class AppleEvidenceRejected implements Exception {
  const AppleEvidenceRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppleOwnershipConflict implements Exception {
  const AppleOwnershipConflict();
  @override
  String toString() => 'Apple transaction đã thuộc XS GO account khác';
}

/// Chỉ adapter trust implementation mới được tạo model này từ JWS Apple.
/// Service vẫn kiểm tra lại mọi business claim trước khi ghi ledger.
class AppleVerifiedTransaction {
  const AppleVerifiedTransaction({
    required this.bundleId,
    required this.environment,
    required this.productId,
    required this.transactionId,
    required this.originalTransactionId,
    required this.appAccountToken,
    required this.kind,
    required this.status,
    required this.purchasedAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.transactionJwsVerified,
    required this.serverApiReconciled,
  });

  final String bundleId;
  final String environment;
  final String productId;
  final String transactionId;
  final String originalTransactionId;
  final String appAccountToken;
  final String kind;
  final String status;
  final int purchasedAt;
  final int expiresAt;
  final int revokedAt;
  final bool transactionJwsVerified;

  /// True chỉ khi adapter đã đối chiếu Get Transaction Info bằng App Store
  /// Server API; client-supplied JWS một mình không đủ để cấp quyền.
  final bool serverApiReconciled;

  AppleVerifiedTransaction copyWith({
    String? bundleId,
    String? environment,
    String? productId,
    String? transactionId,
    String? originalTransactionId,
    String? appAccountToken,
    String? kind,
    String? status,
    int? purchasedAt,
    int? expiresAt,
    int? revokedAt,
    bool? transactionJwsVerified,
    bool? serverApiReconciled,
  }) =>
      AppleVerifiedTransaction(
        bundleId: bundleId ?? this.bundleId,
        environment: environment ?? this.environment,
        productId: productId ?? this.productId,
        transactionId: transactionId ?? this.transactionId,
        originalTransactionId:
            originalTransactionId ?? this.originalTransactionId,
        appAccountToken: appAccountToken ?? this.appAccountToken,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        purchasedAt: purchasedAt ?? this.purchasedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        revokedAt: revokedAt ?? this.revokedAt,
        transactionJwsVerified:
            transactionJwsVerified ?? this.transactionJwsVerified,
        serverApiReconciled: serverApiReconciled ?? this.serverApiReconciled,
      );
}

class AppleVerifiedNotification {
  const AppleVerifiedNotification({
    required this.notificationId,
    required this.notificationType,
    required this.bundleId,
    required this.environment,
    required this.outerJwsVerified,
    required this.transactionJwsVerified,
    required this.renewalInfoJwsVerified,
    required this.transaction,
  });

  final String notificationId;
  final String notificationType;
  final String bundleId;
  final String environment;
  final bool outerJwsVerified;
  final bool transactionJwsVerified;
  final bool renewalInfoJwsVerified;
  final AppleVerifiedTransaction transaction;
}

abstract interface class AppleVerifier {
  bool get configured;

  /// Trusted implementation must verify transaction JWS certificate chain,
  /// then reconcile the same transaction through Get Transaction Info.
  Future<AppleVerifiedTransaction> verifyAndReconcileTransaction(
      String signedTransaction);

  /// Trusted implementation must verify outer signedPayload plus nested
  /// signedTransactionInfo and signedRenewalInfo before returning.
  Future<AppleVerifiedNotification> verifyNotification(String signedPayload);
}

/// Production-safe default. Routes exist, but no Apple evidence can grant an
/// entitlement until a reviewed trust adapter is explicitly injected.
class UnconfiguredAppleVerifier implements AppleVerifier {
  @override
  bool get configured => false;

  @override
  Future<AppleVerifiedTransaction> verifyAndReconcileTransaction(
          String signedTransaction) async =>
      throw const AppleVerificationUnavailable();

  @override
  Future<AppleVerifiedNotification> verifyNotification(
          String signedPayload) async =>
      throw const AppleVerificationUnavailable();
}

class AppleProductCatalog {
  AppleProductCatalog._();

  static const products = <String, String>{
    'com.xsgo.xsGo.video.monthly': 'video_monthly',
    'com.xsgo.xsGo.video.yearly': 'video_yearly',
    'com.xsgo.xsGo.bjt.lifetime': 'bjt_lifetime',
    'com.xsgo.xsGo.allaccess.lifetime': 'all_access_lifetime',
    'com.xsgo.xsGo.tokutei.kaigo': 'tokutei_kaigo',
    'com.xsgo.xsGo.tokutei.gaishoku': 'tokutei_gaishoku',
    'com.xsgo.xsGo.tokutei.inshoku': 'tokutei_inshoku',
    'com.xsgo.xsGo.tokutei.kensetsu': 'tokutei_kensetsu',
    'com.xsgo.xsGo.tokutei.shukuhaku': 'tokutei_shukuhaku',
    'com.xsgo.xsGo.tokutei.nogyo': 'tokutei_nogyo',
    'com.xsgo.xsGo.tokutei.kogyo': 'tokutei_kogyo',
    'com.xsgo.xsGo.tokutei.building': 'tokutei_building',
    'com.xsgo.xsGo.tokutei.jidosha': 'tokutei_jidosha',
    'com.xsgo.xsGo.tokutei.gyogyo': 'tokutei_gyogyo',
    'com.xsgo.xsGo.tokutei.zosen': 'tokutei_zosen',
    'com.xsgo.xsGo.tokutei.koku': 'tokutei_koku',
    'com.xsgo.xsGo.tokutei.unso': 'tokutei_unso',
    'com.xsgo.xsGo.tokutei.tetsudo': 'tokutei_tetsudo',
    'com.xsgo.xsGo.tokutei.ringyo': 'tokutei_ringyo',
    'com.xsgo.xsGo.tokutei.mokuzai': 'tokutei_mokuzai',
  };

  static String? entitlementOf(String productId) => products[productId];

  static String? kindOf(String productId) {
    if (!products.containsKey(productId)) return null;
    return productId == 'com.xsgo.xsGo.video.monthly' ||
            productId == 'com.xsgo.xsGo.video.yearly'
        ? 'subscription'
        : 'non_consumable';
  }
}

class AppleBillingResult {
  const AppleBillingResult(this.status, this.owned);
  final String status;
  final List<String> owned;
}

class AppleBillingService {
  AppleBillingService(this._db, this._verifier);

  static const bundleId = 'com.xsgo.xsGo';
  static const environments = {'Sandbox', 'Production'};
  static const activeStatuses = {'active', 'grace'};
  static const terminalStatuses = {
    'expired',
    'revoked',
    'refunded',
    'canceled'
  };

  final Db _db;
  final AppleVerifier _verifier;

  bool get configured => _verifier.configured;

  Future<AppleBillingResult> verifyPurchase(
      int userId, String signedTransaction) async {
    if (!_verifier.configured) throw const AppleVerificationUnavailable();
    final evidence =
        await _verifier.verifyAndReconcileTransaction(signedTransaction);
    _validateEvidence(evidence, requireServerReconciliation: true);
    final accountToken = _db.billingAccountToken(userId);
    if (evidence.appAccountToken != accountToken) {
      throw const AppleEvidenceRejected('appAccountToken không khớp account');
    }
    _checkOwnership(userId, evidence);
    _apply(userId, evidence);
    return AppleBillingResult(evidence.status, _db.userEntitlements(userId));
  }

  Future<bool> processNotification(String signedPayload) async {
    if (!_verifier.configured) throw const AppleVerificationUnavailable();
    final notification = await _verifier.verifyNotification(signedPayload);
    final tx = notification.transaction;
    if (!notification.outerJwsVerified ||
        !notification.transactionJwsVerified ||
        !tx.transactionJwsVerified) {
      throw const AppleEvidenceRejected('Apple notification JWS chưa verify');
    }
    if (tx.kind == 'subscription' && !notification.renewalInfoJwsVerified) {
      throw const AppleEvidenceRejected('signedRenewalInfo chưa verify');
    }
    if (notification.bundleId != tx.bundleId ||
        notification.environment != tx.environment) {
      throw const AppleEvidenceRejected('Outer/nested claims không khớp');
    }
    _validateEvidence(tx, requireServerReconciliation: false);
    if (notification.notificationId.isEmpty) {
      throw const AppleEvidenceRejected('Thiếu notificationUUID');
    }
    final userId = _db.userIdByBillingAccountToken(tx.appAccountToken);
    final existing = _db.storeTransactionByOriginal(
      store: 'apple',
      environment: tx.environment,
      originalTransactionId: tx.originalTransactionId,
    );
    final owner = existing?['user_id'] as int? ?? userId;
    if (owner == null && existing == null) {
      throw const AppleEvidenceRejected('Không tìm thấy XS GO account owner');
    }
    if (owner != null) _checkOwnership(owner, tx);
    final digest = sha256.convert(utf8.encode(signedPayload)).toString();
    final shouldProcess = _db.beginStoreEvent(
      store: 'apple',
      environment: tx.environment,
      eventId: notification.notificationId,
      eventType: notification.notificationType,
      payloadHash: digest,
      signedPayload: signedPayload,
    );
    if (!shouldProcess) return false;
    if (owner == null) {
      _applyDetached(tx);
    } else {
      _apply(owner, tx);
    }
    _db.completeStoreEvent(
      store: 'apple',
      environment: tx.environment,
      eventId: notification.notificationId,
    );
    return true;
  }

  void _validateEvidence(AppleVerifiedTransaction tx,
      {required bool requireServerReconciliation}) {
    if (!tx.transactionJwsVerified) {
      throw const AppleEvidenceRejected('Transaction JWS chưa verify');
    }
    if (requireServerReconciliation && !tx.serverApiReconciled) {
      throw const AppleEvidenceRejected('App Store Server API chưa reconcile');
    }
    if (tx.bundleId != bundleId || !environments.contains(tx.environment)) {
      throw const AppleEvidenceRejected('Bundle/environment không hợp lệ');
    }
    if (AppleProductCatalog.entitlementOf(tx.productId) == null) {
      throw const AppleEvidenceRejected('Apple product không thuộc allowlist');
    }
    if (tx.kind != AppleProductCatalog.kindOf(tx.productId)) {
      throw const AppleEvidenceRejected('Apple product type không hợp lệ');
    }
    if (tx.transactionId.isEmpty ||
        tx.originalTransactionId.isEmpty ||
        tx.appAccountToken.isEmpty ||
        tx.transactionId.length > 256 ||
        tx.originalTransactionId.length > 256) {
      throw const AppleEvidenceRejected('Transaction identity không hợp lệ');
    }
    if (!activeStatuses.contains(tx.status) &&
        !terminalStatuses.contains(tx.status)) {
      throw const AppleEvidenceRejected('Transaction status không hợp lệ');
    }
  }

  void _checkOwnership(int userId, AppleVerifiedTransaction tx) {
    final direct = _db.storeTransaction(
      store: 'apple',
      environment: tx.environment,
      transactionId: tx.transactionId,
    );
    final original = _db.storeTransactionByOriginal(
      store: 'apple',
      environment: tx.environment,
      originalTransactionId: tx.originalTransactionId,
    );
    for (final existing in [direct, original]) {
      if (existing != null &&
          (existing['user_id'] != userId ||
              existing['account_token'] != tx.appAccountToken)) {
        throw const AppleOwnershipConflict();
      }
    }
  }

  void _apply(int userId, AppleVerifiedTransaction tx) {
    final entitlement = AppleProductCatalog.entitlementOf(tx.productId)!;
    _db.upsertStoreTransaction(
      store: 'apple',
      environment: tx.environment,
      transactionId: tx.transactionId,
      originalTransactionId: tx.originalTransactionId,
      userId: userId,
      accountToken: tx.appAccountToken,
      productId: tx.productId,
      entitlementKey: entitlement,
      kind: tx.kind,
      status: tx.status,
      purchasedAt: tx.purchasedAt,
      expiresAt: tx.expiresAt,
      revokedAt: tx.revokedAt,
    );
    _db.upsertStoreEntitlementGrant(
      store: 'apple',
      environment: tx.environment,
      transactionId: tx.transactionId,
      userId: userId,
      entitlementKey: entitlement,
      status: tx.status,
      expiresAt: tx.expiresAt,
    );
  }

  void _applyDetached(AppleVerifiedTransaction tx) {
    _db.upsertDetachedStoreTransaction(
      store: 'apple',
      environment: tx.environment,
      transactionId: tx.transactionId,
      originalTransactionId: tx.originalTransactionId,
      accountToken: tx.appAccountToken,
      productId: tx.productId,
      entitlementKey: AppleProductCatalog.entitlementOf(tx.productId)!,
      kind: tx.kind,
      status: tx.status,
      purchasedAt: tx.purchasedAt,
      expiresAt: tx.expiresAt,
      revokedAt: tx.revokedAt,
    );
  }
}
