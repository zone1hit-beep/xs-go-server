# XS GO Apple Verifier Sidecar

## Scope and safety

This phase completes the Phase 3B trust adapter without deploying it. It does
not enable selling, change the Google Billing API contract, run a production
migration, or upload an app build. The Android versionCode 2 closed-testing
artifact remains untouched.

The Apple private key is never part of this repository or image. Runtime reads
it from `APPLE_IAP_KEY_PATH`; local development points that variable at a file
outside the repository. Internal authentication uses only
`XSGO_APPLE_VERIFIER_TOKEN` from the environment.

## Architecture

The Fly image contains two application processes:

- Dart remains the only public process on `0.0.0.0:8091`.
- Node 22 binds the verifier to `127.0.0.1:9000`; Fly exposes no service for
  that port.

When the complete Apple verifier configuration is absent, the supervisor starts
Dart alone. Existing Android clients and all non-Apple routes therefore retain
their current behavior, while Apple verification remains the existing
fail-closed 503 path. When the complete configuration is present, the
supervisor starts both processes. If Node stops, Dart stays available for
Android and non-Apple APIs while Apple verification returns fail-closed 503.
Only Dart stopping terminates the sidecar and exits the container so Fly can
restart the public service after a future deployment.

The sidecar uses Apple's official
`@apple/app-store-server-library@3.1.0`. `SignedDataVerifier` performs JWS,
certificate-chain, bundle, environment, and Production appAppleId validation;
online certificate checks remain enabled. XS GO does not implement JWS or
X.509 validation itself.

## Dart to Node interface

All POST routes require `Authorization: Bearer
<XSGO_APPLE_VERIFIER_TOKEN>`, enforce a bounded JSON body, and return only
normalized verified evidence.

- `GET /health` returns only readiness state; it never returns Key ID, Issuer
  ID, private-key path/content, token, or Apple credential metadata.
- `POST /verify/transaction` verifies a StoreKit signed transaction using
  `SignedDataVerifier` and returns normalized verified claims.
- `POST /verify/notification` verifies the outer Notifications V2 JWS, then
  explicitly verifies nested `signedTransactionInfo` and
  `signedRenewalInfo` when present/required.
- `POST /transaction/info` calls Get Transaction Info using the verified
  transaction identifier, verifies Apple's returned signed transaction, and
  returns normalized authoritative claims.

For purchase verification, Dart first receives verified device evidence, then
requests Get Transaction Info and compares transaction ID, original transaction
ID, bundle, environment, product, type, and appAccountToken. Only the verified
authoritative result is marked reconciled and allowed to reach the ledger.
Product allowlisting and XS GO account ownership remain independently enforced
by the Dart Phase 3B layer.

## Root CA strategy

The repository vendors DER certificates downloaded only from the **Apple Root
Certificates** section of [Apple PKI](https://www.apple.com/certificateauthority/).
A manifest records SHA-256 fingerprints and source URLs. Automated tests hash
the actual DER files and fail on an unexpected replacement. Runtime never
downloads trust anchors and never disables certificate validation.

Update procedure:

1. Review the Apple PKI root-certificate list and Apple's server-library
   release notes.
2. Download new/replaced roots directly from `apple.com` over HTTPS.
3. Independently inspect subject, issuer, validity, and SHA-256 with OpenSSL.
4. Update the DER asset and manifest in a reviewed pull request.
5. Run Node trust/config tests and the complete Dart test suite before rollout.

## Fail-closed behavior

- Missing/partial configuration: Dart uses `UnconfiguredAppleVerifier`; Apple
  purchase/notification verification cannot grant an entitlement.
- Invalid JWS, bundle, environment, appAppleId, product, transaction identity,
  or appAccountToken: rejected.
- Sidecar unavailable, timeout, malformed response, internal token mismatch,
  or transient Apple API failure: no fallback and no entitlement grant.
- Production requires a positive numeric `APPLE_APP_ID`; Sandbox passes no
  appAppleId to the official verifier as required by Apple.

## Sandbox smoke-test interpretation

A local Get Transaction Info request using a deliberately nonexistent
transaction/original-transaction identifier is read-only. A correctly typed
Apple transaction-not-found response demonstrates only network connectivity,
credential signing, and Apple API authentication. It is **not** evidence that a
purchase JWS verifies end to end. End-to-end verification remains blocked until
the owner supplies a real Sandbox/TestFlight transaction.

## Runtime configuration

Required to enable the sidecar:

- `APPLE_IAP_KEY_PATH`
- `APPLE_IAP_KEY_ID`
- `APPLE_IAP_ISSUER_ID`
- `APPLE_BUNDLE_ID`
- `APPLE_APP_ID`
- `APPLE_ENVIRONMENT` (`SANDBOX` first; `PRODUCTION` is separately validated)
- `XSGO_APPLE_VERIFIER_TOKEN`

For Fly, `APPLE_IAP_PRIVATE_KEY_BASE64` may contain the runtime-only base64
key. The supervisor writes it to the absolute `APPLE_IAP_KEY_PATH` with mode
`0600` before starting Node. This value is not part of the enablement decision,
is never returned by health, and is never logged.

The implementation may accept private-key content from a Fly secret only to
materialize an ephemeral mode-0600 runtime file before the sidecar starts. The
key must never be copied into the image, repository, logs, docs, or tests.

## Owner actions before any deployment

1. Create all reviewed App Store Connect products and the subscription group;
   do not replace proposal IDs with unreviewed values.
2. Configure the Sandbox Notifications V2 URL only after the server PR is
   reviewed and a deployment is explicitly approved.
3. Store the IAP private key, Key ID, Issuer ID, bundle ID, numeric app ID,
   environment, and a new high-entropy verifier token as Fly secrets/runtime
   config.
4. Provide a real Sandbox/TestFlight transaction for end-to-end purchase,
   restore, notification, and reconciliation tests.
5. Complete Sandbox evidence and review before enabling Production or selling.

## Verification report

Implemented locally:

- Official Node library `3.1.0` verifies transaction JWS, Notifications V2
  outer/nested JWS, certificate trust, bundle and environment; trust anchors
  are three reviewed Apple PKI DER roots pinned by SHA-256 tests.
- Dart calls the loopback sidecar, reconciles purchases using Get Transaction
  Info, compares verified transaction identity, and preserves the Phase 3B
  product/account/idempotency checks.
- Internal auth, credential-free health, bounded request bodies, timeout/socket
  failure, partial config, runtime-key permissions and watchdog behavior have
  automated tests.
- The image declares Node 22, keeps Dart on `8091`, exposes only `8091`, and
  starts Dart-only when Apple configuration is absent/incomplete.

Read-only Sandbox smoke result on 2026-08-14:

- `AUTH_CONNECTIVITY_PASS_TRANSACTION_NOT_FOUND`
- `jwsVerification: NOT_TESTED`

This is evidence only that the provided key/issuer/bundle combination could
authenticate to the Sandbox App Store Server API over the network. It is not a
purchase-verification result.

Automated verification on 2026-08-14:

- Node 22 native suite: 22/22 PASS.
- Dart server suite: 84/84 PASS.
- `dart analyze`: PASS, no issues.
- `npm audit --omit=dev`: PASS, 0 vulnerabilities.
- Live local sidecar `/health`: exactly `{"ok":true}`.
- Changed-worktree private-key/credential scan: PASS; no `.p8` is tracked or
  copied into the Docker build context.

Still fail-closed / blocked before deployment:

- No real Sandbox/TestFlight transaction JWS was supplied, so purchase,
  restore, device reinstall/account switch and Get Transaction Info identity
  reconciliation are not proven end to end against Apple.
- No real Notifications V2 delivery has exercised outer plus nested JWS and
  lifecycle ordering against Apple.
- Production credentials/environment and Production JWS remain untested;
  selling remains OFF.
- Docker is not installed in the local execution environment, so the image
  topology is statically defined and unit-tested but the final container build
  must run in CI/review before any deploy approval.

Runtime decision: keep the official Node 22 verifier in the **same container**,
not a separately exposed service. A safe Dart-only replacement was not found;
XS GO therefore does not hand-roll Apple X.509/JWS validation in Dart.
