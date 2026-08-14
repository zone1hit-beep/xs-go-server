import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { appleConfigEnabled, loadConfig } from '../src/config.js';
import { startHttpServer } from '../src/http_server.js';

const completeEnv = {
  APPLE_IAP_KEY_PATH: '/outside/repo/key.p8',
  APPLE_IAP_KEY_ID: 'KEY1234567',
  APPLE_IAP_ISSUER_ID: '11111111-2222-3333-4444-555555555555',
  APPLE_BUNDLE_ID: 'com.xsgo.xsGo',
  APPLE_APP_ID: '6800309856',
  APPLE_ENVIRONMENT: 'SANDBOX',
  XSGO_APPLE_VERIFIER_TOKEN: 'a'.repeat(48),
};

test('Apple config absent keeps optional sidecar disabled; partial config rejects', () => {
  assert.equal(appleConfigEnabled({}), false);
  assert.equal(appleConfigEnabled(completeEnv), true);
  assert.throws(
    () => loadConfig({...completeEnv, APPLE_IAP_KEY_ID: ''}),
    /partial Apple verifier configuration/,
  );
  assert.throws(
    () => loadConfig({...completeEnv, APPLE_ENVIRONMENT: 'Production'}),
    /APPLE_ENVIRONMENT/,
  );
});

test('production requires a positive numeric Apple app ID', () => {
  assert.throws(
    () => loadConfig({...completeEnv, APPLE_ENVIRONMENT: 'PRODUCTION', APPLE_APP_ID: '0'}),
    /APPLE_APP_ID/,
  );
});

test('health is credential-free and POST requires the shared ENV token', async (t) => {
  const server = await startHttpServer({
    host: '127.0.0.1',
    port: 0,
    token: completeEnv.XSGO_APPLE_VERIFIER_TOKEN,
    service: {
      verifyTransaction: async () => ({transactionId: 'verified'}),
      verifyNotification: async () => ({notificationId: 'verified'}),
      getTransactionInfo: async () => ({transactionId: 'authoritative'}),
    },
  });
  t.after(() => server.close());
  const {port} = server.address();
  const base = `http://127.0.0.1:${port}`;

  const health = await fetch(`${base}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), {ok: true});
  const healthText = JSON.stringify(await (await fetch(`${base}/health`)).json());
  for (const secret of Object.values(completeEnv)) {
    assert.equal(healthText.includes(secret), false);
  }

  const denied = await fetch(`${base}/verify/transaction`, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({signedTransaction: 'jws'}),
  });
  assert.equal(denied.status, 401);

  const allowed = await fetch(`${base}/verify/transaction`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${completeEnv.XSGO_APPLE_VERIFIER_TOKEN}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({signedTransaction: 'jws'}),
  });
  assert.equal(allowed.status, 200);
  assert.deepEqual(await allowed.json(), {transactionId: 'verified'});
});

test('sidecar rejects oversized bodies before invoking verification', async (t) => {
  let invoked = false;
  const server = await startHttpServer({
    host: '127.0.0.1',
    port: 0,
    token: completeEnv.XSGO_APPLE_VERIFIER_TOKEN,
    maxBodyBytes: 64,
    service: {
      verifyTransaction: async () => {
        invoked = true;
        return {};
      },
    },
  });
  t.after(() => server.close());
  const {port} = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/verify/transaction`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${completeEnv.XSGO_APPLE_VERIFIER_TOKEN}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({signedTransaction: 'x'.repeat(100)}),
  });
  assert.equal(response.status, 413);
  assert.equal(invoked, false);
});

test('vendored Apple DER roots match the reviewed SHA-256 manifest', async () => {
  const certDir = path.resolve(import.meta.dirname, '../certs');
  const manifest = await readFile(path.join(certDir, 'fingerprints.sha256'), 'utf8');
  const entries = manifest.trim().split('\n').map((line) => line.split(/\s+/));
  assert.deepEqual(entries.map((entry) => entry[1]), [
    'AppleIncRootCertificate.cer',
    'AppleRootCA-G2.cer',
    'AppleRootCA-G3.cer',
  ]);
  for (const [expected, name] of entries) {
    const bytes = await readFile(path.join(certDir, name));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), expected);
  }
});
