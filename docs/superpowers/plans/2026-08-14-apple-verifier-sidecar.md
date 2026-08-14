# Apple Verifier Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an official Apple App Store Server Library sidecar and a fail-closed Dart HTTP adapter without changing the Android Billing contract or deploying production.

**Architecture:** Node 22 runs Apple's library on loopback port 9000 and returns only normalized verified evidence to Dart. Dart remains public on port 8091, reconciles verified device evidence against Get Transaction Info, and uses the existing ledger/account/product validation before granting anything.

**Tech Stack:** Dart 3/shelf/http, Node.js 22 native HTTP/test runner, `@apple/app-store-server-library@3.1.0`, Docker/Fly single-machine topology.

**Spec:** `docs/audit/APPLE_VERIFIER_SIDECAR.md`

## Global Constraints

- Baseline is exactly `a68769b549d7db553fc4089445c27aaa865c4fad`.
- Node binds only `127.0.0.1:9000`; Dart remains on `8091`.
- Never commit, copy, print, or log private `.p8` contents.
- Root certificates come only from Apple PKI, remain DER, and have pinned SHA-256 fingerprints.
- All Apple entitlement decisions fail closed; no fallback verifier exists.
- Missing Apple config must not stop Dart or Android versionCode 2 clients.
- No merge, deploy, production migration, selling enablement, or store upload.

---

### Task 1: Sidecar configuration, roots, and secure HTTP boundary

**Files:**
- Create: `apple_verifier/package.json`
- Create: `apple_verifier/src/config.js`
- Create: `apple_verifier/src/http_server.js`
- Create: `apple_verifier/certs/*.cer`
- Create: `apple_verifier/certs/fingerprints.sha256`
- Test: `apple_verifier/test/config_http.test.js`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `loadConfig(env)`, `startHttpServer(options)`, and verified root buffers for the Apple service.

- [ ] Write Node tests proving partial config is disabled/rejected, health exposes no credential metadata, POST requests require the ENV token, bodies are bounded, and DER hashes match literal fingerprints.
- [ ] Run `npm test` and verify RED because the sidecar modules/assets do not exist.
- [ ] Add the exact Apple dependency, strict config validation, constant-time bearer-token check, bounded JSON parser, Apple-only DER assets, fingerprint manifest, and `*.p8` ignore.
- [ ] Run Node tests and verify GREEN.

### Task 2: Official Apple verification and API reconciliation

**Files:**
- Create: `apple_verifier/src/apple_service.js`
- Create: `apple_verifier/src/evidence.js`
- Create: `apple_verifier/src/server.js`
- Test: `apple_verifier/test/apple_service.test.js`

**Interfaces:**
- Consumes: Apple `SignedDataVerifier`, `AppStoreServerAPIClient`, validated config, and root buffers.
- Produces: `verifyTransaction(jws)`, `verifyNotification(jws)`, and `getTransactionInfo(transactionId)` normalized results.

- [ ] Write tests for invalid JWS, wrong bundle/environment, explicit nested transaction/renewal verification, authoritative transaction lookup, unsupported/malformed claims, and sanitized errors/logs.
- [ ] Run targeted Node tests and verify RED because the Apple service does not exist.
- [ ] Implement the minimal official-library service and evidence normalization; keep online checks enabled and return no raw untrusted claims.
- [ ] Run targeted and full Node tests and verify GREEN.

### Task 3: Dart fail-closed HTTP adapter

**Files:**
- Create: `lib/apple_verifier_http.dart`
- Test: `test/apple_verifier_http_test.dart`
- Modify: `bin/server.dart`

**Interfaces:**
- Produces: `appleVerifierFromEnvironment(env, {client, timeout})` implementing the existing `AppleVerifier` interface.

- [ ] Write Dart tests for missing config, internal token header, valid two-step verification/reconciliation, mismatched authoritative identity, invalid evidence, timeout, unavailable sidecar, and malformed sidecar responses.
- [ ] Run the targeted Dart test and verify RED because the adapter does not exist.
- [ ] Implement strict response parsing/error mapping and inject the adapter into `buildRouter`; do not modify Google routes/contracts.
- [ ] Run targeted adapter, billing, and API tests and verify GREEN.

### Task 4: Optional watchdog and Docker topology

**Files:**
- Create: `apple_verifier/src/supervisor.js`
- Test: `apple_verifier/test/supervisor.test.js`
- Modify: `Dockerfile`
- Modify: `fly.toml` only if a health check is required; never expose port 9000.

**Interfaces:**
- Produces: a container entrypoint that starts Dart alone when Apple config is absent, or supervises Dart plus Node when enabled.

- [ ] Write tests proving incomplete config starts Dart-only and complete config supervises both/propagates child failure without leaking secrets.
- [ ] Run the targeted Node test and verify RED because the supervisor does not exist.
- [ ] Implement the supervisor and Node 22 multi-stage Docker image while preserving public port 8091 and 512 MB declaration.
- [ ] Run Node tests, Docker build, and a no-Apple-config container health probe; verify GREEN.

### Task 5: Sandbox authentication smoke, documentation, and compatibility

**Files:**
- Create: `apple_verifier/scripts/sandbox_auth_smoke.js`
- Modify: `docs/audit/APPLE_VERIFIER_SIDECAR.md`
- Modify: `README.md`
- Modify: `DEPLOY.md`

**Interfaces:**
- Produces: a read-only local credential/network/auth smoke command whose result cannot be mistaken for purchase-JWS verification.

- [ ] Add a smoke script that calls Get Transaction Info with a deliberately nonexistent ID and reports authenticated transaction-not-found separately from auth/network failure, without logging credentials.
- [ ] If local config/key are available, run the smoke safely and record the exact classification; never call purchase or request-test-notification APIs.
- [ ] Run full `npm test`, `npm audit`, `dart analyze`, `dart test`, Docker topology checks, secret scans, and Git diff checks.
- [ ] Update the audit report with test counts, smoke limitations, Fly secrets, owner actions, readiness, and Android backward compatibility.
- [ ] Commit, push `codex/apple-verifier-sidecar`, create a PR into `main`, and stop without merging or deploying.
