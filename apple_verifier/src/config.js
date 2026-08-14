import path from 'node:path';

const requiredKeys = [
  'APPLE_IAP_KEY_PATH',
  'APPLE_IAP_KEY_ID',
  'APPLE_IAP_ISSUER_ID',
  'APPLE_BUNDLE_ID',
  'APPLE_APP_ID',
  'APPLE_ENVIRONMENT',
  'XSGO_APPLE_VERIFIER_TOKEN',
];

const value = (env, key) => `${env[key] ?? ''}`.trim();

export function appleConfigEnabled(env) {
  const present = requiredKeys.filter((key) => value(env, key).length > 0);
  if (present.length === 0) return false;
  if (present.length !== requiredKeys.length) {
    throw new Error('partial Apple verifier configuration');
  }
  return true;
}

export function loadConfig(env) {
  if (!appleConfigEnabled(env)) {
    throw new Error('Apple verifier configuration is absent');
  }
  const environment = value(env, 'APPLE_ENVIRONMENT');
  if (environment !== 'SANDBOX' && environment !== 'PRODUCTION') {
    throw new Error('APPLE_ENVIRONMENT must be SANDBOX or PRODUCTION');
  }
  const appAppleId = Number(value(env, 'APPLE_APP_ID'));
  if (!Number.isSafeInteger(appAppleId) || appAppleId <= 0) {
    throw new Error('APPLE_APP_ID must be a positive integer');
  }
  const token = value(env, 'XSGO_APPLE_VERIFIER_TOKEN');
  if (token.length < 32) {
    throw new Error('XSGO_APPLE_VERIFIER_TOKEN must contain at least 32 characters');
  }
  return Object.freeze({
    keyPath: value(env, 'APPLE_IAP_KEY_PATH'),
    keyId: value(env, 'APPLE_IAP_KEY_ID'),
    issuerId: value(env, 'APPLE_IAP_ISSUER_ID'),
    bundleId: value(env, 'APPLE_BUNDLE_ID'),
    appAppleId,
    environment,
    token,
    rootCertificatePaths: [
      path.resolve(import.meta.dirname, '../certs/AppleIncRootCertificate.cer'),
      path.resolve(import.meta.dirname, '../certs/AppleRootCA-G2.cer'),
      path.resolve(import.meta.dirname, '../certs/AppleRootCA-G3.cer'),
    ],
  });
}

export const appleVerifierRequiredKeys = Object.freeze([...requiredKeys]);
