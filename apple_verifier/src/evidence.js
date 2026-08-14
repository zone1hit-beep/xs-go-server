const expectedEnvironment = (environment) =>
  environment === 'PRODUCTION' ? 'Production' : 'Sandbox';

const requiredString = (value, field) => {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new EvidenceError(`missing_${field}`);
  }
  return value.trim();
};

const requiredTimestamp = (value, field) => {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new EvidenceError(`invalid_${field}`);
  }
  return value;
};

export class EvidenceError extends Error {
  constructor(reason = 'invalid_evidence') {
    super('Apple evidence rejected');
    this.name = 'EvidenceError';
    this.code = 'evidence_rejected';
    this.reason = reason;
    this.statusCode = 422;
  }
}

export class AppleApiUnavailableError extends Error {
  constructor() {
    super('Apple API unavailable');
    this.name = 'AppleApiUnavailableError';
    this.code = 'apple_api_unavailable';
    this.statusCode = 503;
  }
}

function kindOf(type) {
  if (type === 'Auto-Renewable Subscription') return 'subscription';
  if (type === 'Non-Consumable') return 'non_consumable';
  throw new EvidenceError('unsupported_product_type');
}

function baseStatus(transaction, now) {
  if (Number.isSafeInteger(transaction.revocationDate) && transaction.revocationDate > 0) {
    return 'revoked';
  }
  if (transaction.type === 'Auto-Renewable Subscription') {
    return Number.isSafeInteger(transaction.expiresDate) && transaction.expiresDate > now
      ? 'active'
      : 'expired';
  }
  return 'active';
}

function notificationStatus(notificationType, dataStatus, transaction, now) {
  if (notificationType === 'REFUND') return 'refunded';
  if (notificationType === 'REVOKE') return 'revoked';
  if (notificationType === 'EXPIRED' || notificationType === 'GRACE_PERIOD_EXPIRED') {
    return 'expired';
  }
  if (dataStatus === 5) return 'revoked';
  if (dataStatus === 4) return 'grace';
  if (dataStatus === 2 || dataStatus === 3) return 'expired';
  if (notificationType === 'REFUND_REVERSED') return 'active';
  return baseStatus(transaction, now);
}

export function normalizeTransaction(transaction, config, {
  now = Date.now(),
  status,
  serverApiReconciled = false,
} = {}) {
  if (transaction?.bundleId !== config.bundleId) {
    throw new EvidenceError('bundle_mismatch');
  }
  if (transaction?.environment !== expectedEnvironment(config.environment)) {
    throw new EvidenceError('environment_mismatch');
  }
  const type = requiredString(transaction.type, 'type');
  return Object.freeze({
    bundleId: transaction.bundleId,
    environment: transaction.environment,
    productId: requiredString(transaction.productId, 'productId'),
    transactionId: requiredString(transaction.transactionId, 'transactionId'),
    originalTransactionId: requiredString(
      transaction.originalTransactionId,
      'originalTransactionId',
    ),
    appAccountToken: requiredString(transaction.appAccountToken, 'appAccountToken'),
    kind: kindOf(type),
    status: status ?? baseStatus(transaction, now),
    signedDate: requiredTimestamp(transaction.signedDate, 'signedDate'),
    purchasedAt: requiredTimestamp(transaction.purchaseDate, 'purchaseDate'),
    expiresAt: Number.isSafeInteger(transaction.expiresDate) ? transaction.expiresDate : 0,
    revokedAt: Number.isSafeInteger(transaction.revocationDate)
      ? transaction.revocationDate
      : 0,
    transactionJwsVerified: true,
    serverApiReconciled,
  });
}

export function normalizeNotification(outer, transaction, renewalVerified, config, now = Date.now()) {
  if (outer?.data?.bundleId !== config.bundleId) {
    throw new EvidenceError('notification_bundle_mismatch');
  }
  if (outer?.data?.environment !== expectedEnvironment(config.environment)) {
    throw new EvidenceError('notification_environment_mismatch');
  }
  const notificationType = requiredString(outer.notificationType, 'notificationType');
  const status = notificationStatus(
    notificationType,
    outer.data.status,
    transaction,
    now,
  );
  return Object.freeze({
    notificationId: requiredString(outer.notificationUUID, 'notificationUUID'),
    notificationType,
    bundleId: outer.data.bundleId,
    environment: outer.data.environment,
    signedDate: requiredTimestamp(outer.signedDate, 'notificationSignedDate'),
    outerJwsVerified: true,
    transactionJwsVerified: true,
    renewalInfoJwsVerified: renewalVerified,
    transaction: normalizeTransaction(transaction, config, {now, status}),
  });
}
