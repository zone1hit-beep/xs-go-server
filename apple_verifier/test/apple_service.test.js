import assert from 'node:assert/strict';
import test from 'node:test';

import {createAppleService, createProductionAppleService} from '../src/apple_service.js';

const config = {
  bundleId: 'com.xsgo.xsGo',
  environment: 'SANDBOX',
  appAppleId: 6800309856,
};

const decodedTransaction = {
  bundleId: 'com.xsgo.xsGo',
  environment: 'Sandbox',
  productId: 'com.xsgo.xsGo.video.monthly',
  transactionId: '2000000123456789',
  originalTransactionId: '2000000123000000',
  appAccountToken: '00000000-0000-4000-8000-000000000001',
  type: 'Auto-Renewable Subscription',
  signedDate: 200,
  purchaseDate: 100,
  expiresDate: 9999999999999,
};

test('invalid JWS is rejected by the real official SignedDataVerifier', async () => {
  const service = await createProductionAppleService({
    ...config,
    keyPath: new URL('../test/fixtures/not-a-key.txt', import.meta.url).pathname,
    keyId: 'KEY1234567',
    issuerId: '11111111-2222-3333-4444-555555555555',
    rootCertificatePaths: [
      new URL('../certs/AppleIncRootCertificate.cer', import.meta.url).pathname,
      new URL('../certs/AppleRootCA-G2.cer', import.meta.url).pathname,
      new URL('../certs/AppleRootCA-G3.cer', import.meta.url).pathname,
    ],
  });

  await assert.rejects(
    service.verifyTransaction('not-a-jws'),
    (error) => error.code === 'evidence_rejected' && error.statusCode === 422,
  );
});

test('wrong bundle or environment never becomes normalized evidence', async () => {
  for (const changed of [
    {...decodedTransaction, bundleId: 'com.attacker.app'},
    {...decodedTransaction, environment: 'Production'},
  ]) {
    const service = createAppleService({
      config,
      verifier: {verifyAndDecodeTransaction: async () => changed},
      apiClient: {},
    });
    await assert.rejects(
      service.verifyTransaction('signed'),
      (error) => error.code === 'evidence_rejected',
    );
  }
});

test('notification verifies outer plus nested transaction and renewal JWS', async () => {
  const calls = [];
  const verifier = {
    verifyAndDecodeNotification: async (value) => {
      calls.push(['outer', value]);
      return {
        notificationUUID: 'notification-1',
        notificationType: 'DID_RENEW',
        signedDate: 300,
        data: {
          bundleId: 'com.xsgo.xsGo',
          environment: 'Sandbox',
          signedTransactionInfo: 'nested-transaction',
          signedRenewalInfo: 'nested-renewal',
          status: 1,
        },
      };
    },
    verifyAndDecodeTransaction: async (value) => {
      calls.push(['transaction', value]);
      return decodedTransaction;
    },
    verifyAndDecodeRenewalInfo: async (value) => {
      calls.push(['renewal', value]);
      return {signedDate: 250};
    },
  };
  const service = createAppleService({config, verifier, apiClient: {}});

  const result = await service.verifyNotification('outer-signed-payload');

  assert.deepEqual(calls, [
    ['outer', 'outer-signed-payload'],
    ['transaction', 'nested-transaction'],
    ['renewal', 'nested-renewal'],
  ]);
  assert.equal(result.notificationId, 'notification-1');
  assert.equal(result.outerJwsVerified, true);
  assert.equal(result.transactionJwsVerified, true);
  assert.equal(result.renewalInfoJwsVerified, true);
  assert.equal(result.transaction.status, 'active');
  assert.equal(JSON.stringify(result).includes('nested-'), false);
});

test('Get Transaction Info verifies Apple authoritative signed transaction', async () => {
  const calls = [];
  const service = createAppleService({
    config,
    verifier: {
      verifyAndDecodeTransaction: async (value) => {
        calls.push(['verify', value]);
        return {...decodedTransaction, signedDate: 400};
      },
    },
    apiClient: {
      getTransactionInfo: async (transactionId) => {
        calls.push(['api', transactionId]);
        return {signedTransactionInfo: 'authoritative-jws'};
      },
    },
  });

  const result = await service.getTransactionInfo('2000000123456789');

  assert.deepEqual(calls, [
    ['api', '2000000123456789'],
    ['verify', 'authoritative-jws'],
  ]);
  assert.equal(result.transactionId, '2000000123456789');
  assert.equal(result.serverApiReconciled, true);
});

test('Apple API transient failure is unavailable and does not expose cause', async () => {
  const marker = 'PRIVATE_KEY_MUST_NOT_APPEAR';
  const service = createAppleService({
    config,
    verifier: {},
    apiClient: {
      getTransactionInfo: async () => {
        const error = new Error(marker);
        error.httpStatusCode = 500;
        throw error;
      },
    },
  });
  await assert.rejects(service.getTransactionInfo('2000000123456789'), (error) => {
    assert.equal(error.code, 'apple_api_unavailable');
    assert.equal(error.statusCode, 503);
    assert.equal(`${error}`.includes(marker), false);
    return true;
  });
});
