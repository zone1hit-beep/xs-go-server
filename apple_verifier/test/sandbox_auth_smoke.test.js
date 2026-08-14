import assert from 'node:assert/strict';
import test from 'node:test';

import {APIError, APIException} from '@apple/app-store-server-library';

import {classifySmokeOutcome} from '../scripts/sandbox_auth_smoke.js';

test('typed transaction-not-found is auth/connectivity PASS, never JWS PASS', () => {
  const result = classifySmokeOutcome(new APIException(
    404,
    APIError.TRANSACTION_ID_NOT_FOUND,
    'Transaction not found.',
  ));
  assert.deepEqual(result, {
    ok: true,
    code: 'AUTH_CONNECTIVITY_PASS_TRANSACTION_NOT_FOUND',
    jwsVerification: 'NOT_TESTED',
  });
});

test('auth rejection and network/runtime errors never become PASS', () => {
  assert.equal(classifySmokeOutcome(
    new APIException(401, null, 'Unauthorized'),
  ).ok, false);
  assert.equal(classifySmokeOutcome(new Error('socket failed')).ok, false);
});

test('an unexpected response still cannot claim JWS verification', () => {
  const result = classifySmokeOutcome(null);
  assert.equal(result.ok, true);
  assert.equal(result.code, 'AUTH_CONNECTIVITY_PASS_UNEXPECTED_RECORD');
  assert.equal(result.jwsVerification, 'NOT_TESTED');
});
