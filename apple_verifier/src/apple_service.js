import {readFile} from 'node:fs/promises';

import {
  APIException,
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} from '@apple/app-store-server-library';

import {
  AppleApiUnavailableError,
  EvidenceError,
  normalizeNotification,
  normalizeTransaction,
} from './evidence.js';

const validJws = (value) => typeof value === 'string' && value.length > 0 && value.length <= 262144;
const validTransactionId = (value) =>
  typeof value === 'string' && /^[A-Za-z0-9.-]{1,256}$/.test(value);

const evidenceCall = async (operation) => {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof EvidenceError) throw error;
    throw new EvidenceError();
  }
};

export function createAppleService({config, verifier, apiClient, now = Date.now}) {
  return Object.freeze({
    async verifyTransaction(signedTransaction) {
      if (!validJws(signedTransaction)) throw new EvidenceError('invalid_jws_shape');
      const decoded = await evidenceCall(() =>
        verifier.verifyAndDecodeTransaction(signedTransaction));
      return normalizeTransaction(decoded, config, {now: now()});
    },

    async verifyNotification(signedPayload) {
      if (!validJws(signedPayload)) throw new EvidenceError('invalid_jws_shape');
      const outer = await evidenceCall(() =>
        verifier.verifyAndDecodeNotification(signedPayload));
      const transactionJws = outer?.data?.signedTransactionInfo;
      if (!validJws(transactionJws)) throw new EvidenceError('missing_nested_transaction');
      const transaction = await evidenceCall(() =>
        verifier.verifyAndDecodeTransaction(transactionJws));
      let renewalVerified = false;
      const renewalJws = outer?.data?.signedRenewalInfo;
      if (validJws(renewalJws)) {
        await evidenceCall(() => verifier.verifyAndDecodeRenewalInfo(renewalJws));
        renewalVerified = true;
      }
      if (transaction.type === 'Auto-Renewable Subscription' && !renewalVerified) {
        throw new EvidenceError('missing_nested_renewal');
      }
      return normalizeNotification(outer, transaction, renewalVerified, config, now());
    },

    async getTransactionInfo(transactionId) {
      if (!validTransactionId(transactionId)) {
        throw new EvidenceError('invalid_transaction_id');
      }
      let response;
      try {
        response = await apiClient.getTransactionInfo(transactionId);
      } catch (error) {
        if (error instanceof APIException && error.httpStatusCode === 404) {
          throw new EvidenceError('transaction_not_found');
        }
        throw new AppleApiUnavailableError();
      }
      if (!validJws(response?.signedTransactionInfo)) {
        throw new EvidenceError('missing_authoritative_jws');
      }
      const decoded = await evidenceCall(() =>
        verifier.verifyAndDecodeTransaction(response.signedTransactionInfo));
      return normalizeTransaction(decoded, config, {
        now: now(),
        serverApiReconciled: true,
      });
    },
  });
}

export async function createProductionAppleService(config) {
  const [signingKey, ...rootCertificates] = await Promise.all([
    readFile(config.keyPath, 'utf8'),
    ...config.rootCertificatePaths.map((rootPath) => readFile(rootPath)),
  ]);
  const environment = config.environment === 'PRODUCTION'
    ? Environment.PRODUCTION
    : Environment.SANDBOX;
  const verifier = new SignedDataVerifier(
    rootCertificates,
    true,
    environment,
    config.bundleId,
    environment === Environment.PRODUCTION ? config.appAppleId : undefined,
  );
  const apiClient = new AppStoreServerAPIClient(
    signingKey,
    config.keyId,
    config.issuerId,
    config.bundleId,
    environment,
  );
  return createAppleService({config, verifier, apiClient});
}
