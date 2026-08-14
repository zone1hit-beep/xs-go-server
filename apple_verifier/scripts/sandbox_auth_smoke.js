import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

import {
  APIError,
  APIException,
  AppStoreServerAPIClient,
  Environment,
} from '@apple/app-store-server-library';

import {loadConfig} from '../src/config.js';

const authenticatedNotFoundCodes = new Set([
  APIError.TRANSACTION_ID_NOT_FOUND,
  APIError.ORIGINAL_TRANSACTION_ID_NOT_FOUND,
  APIError.ORIGINAL_TRANSACTION_ID_NOT_FOUND_RETRYABLE,
]);

export function classifySmokeOutcome(error) {
  if (error === null) {
    return Object.freeze({
      ok: true,
      code: 'AUTH_CONNECTIVITY_PASS_UNEXPECTED_RECORD',
      jwsVerification: 'NOT_TESTED',
    });
  }
  if (error instanceof APIException &&
      error.httpStatusCode === 404 &&
      authenticatedNotFoundCodes.has(error.apiError)) {
    return Object.freeze({
      ok: true,
      code: 'AUTH_CONNECTIVITY_PASS_TRANSACTION_NOT_FOUND',
      jwsVerification: 'NOT_TESTED',
    });
  }
  return Object.freeze({
    ok: false,
    code: error instanceof APIException
      ? 'APPLE_API_AUTH_OR_REQUEST_FAILED'
      : 'APPLE_API_NETWORK_OR_RUNTIME_FAILED',
    jwsVerification: 'NOT_TESTED',
  });
}

async function withTimeout(operation, milliseconds = 20000) {
  let timer;
  try {
    return await Promise.race([
      operation,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('smoke timeout')), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const config = loadConfig(process.env);
  if (config.environment !== 'SANDBOX') {
    throw new Error('sandbox smoke requires APPLE_ENVIRONMENT=SANDBOX');
  }
  const signingKey = await readFile(config.keyPath, 'utf8');
  const client = new AppStoreServerAPIClient(
    signingKey,
    config.keyId,
    config.issuerId,
    config.bundleId,
    Environment.SANDBOX,
  );
  let error = null;
  try {
    await withTimeout(client.getTransactionInfo('2000000999999999'));
  } catch (caught) {
    error = caught;
  }
  const result = classifySmokeOutcome(error);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (!result.ok) process.exitCode = 1;
}

const invokedDirectly = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  main().catch((error) => {
    process.stderr.write(
      `Sandbox auth/connectivity smoke failed: ${error?.name ?? 'Error'}\n`,
    );
    process.exitCode = 1;
  });
}
