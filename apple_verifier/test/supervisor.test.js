import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {mkdtemp, readFile, stat} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  materializeRuntimeKey,
  runtimeMode,
  supervise,
} from '../src/supervisor.js';

const completeEnv = {
  APPLE_IAP_KEY_PATH: '/runtime/apple.p8',
  APPLE_IAP_KEY_ID: 'KEY1234567',
  APPLE_IAP_ISSUER_ID: '11111111-2222-3333-4444-555555555555',
  APPLE_BUNDLE_ID: 'com.xsgo.xsGo',
  APPLE_APP_ID: '6800309856',
  APPLE_ENVIRONMENT: 'SANDBOX',
  XSGO_APPLE_VERIFIER_TOKEN:
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
};

class FakeChild extends EventEmitter {
  constructor(name) {
    super();
    this.name = name;
    this.kills = [];
  }

  kill(signal) {
    this.kills.push(signal);
    return true;
  }
}

test('absent or incomplete Apple config keeps the runtime Dart-only', () => {
  assert.equal(runtimeMode({}), 'dart-only');
  assert.equal(runtimeMode({APPLE_IAP_KEY_ID: 'partial'}), 'dart-only');
  assert.equal(runtimeMode(completeEnv), 'apple-enabled');
});

test('Dart-only mode never starts or watches the Apple sidecar', async () => {
  const spawns = [];
  const children = [];
  const result = supervise({
    env: {APPLE_IAP_KEY_ID: 'partial'},
    spawnProcess(command, args) {
      spawns.push([command, args]);
      const child = new FakeChild(command);
      children.push(child);
      return child;
    },
    logger: () => {},
    setExitCode: () => {},
  });

  assert.deepEqual(spawns, [['/app/server', []]]);
  assert.equal(result.mode, 'dart-only');
  children[0].emit('exit', 0, null);
  assert.equal(result.exitCode, 0);
});

test('enabled mode starts both and a child death terminates its sibling', () => {
  const children = [];
  const logs = [];
  const result = supervise({
    env: completeEnv,
    spawnProcess(command) {
      const child = new FakeChild(command);
      children.push(child);
      return child;
    },
    logger: (line) => logs.push(line),
    setExitCode: () => {},
  });

  assert.equal(result.mode, 'apple-enabled');
  assert.equal(children.length, 2);
  children[1].emit('exit', 70, null);
  assert.deepEqual(children[0].kills, ['SIGTERM']);
  assert.equal(result.exitCode, 70);
  const output = logs.join('\n');
  for (const secret of [
    completeEnv.APPLE_IAP_KEY_ID,
    completeEnv.APPLE_IAP_ISSUER_ID,
    completeEnv.APPLE_IAP_KEY_PATH,
    completeEnv.XSGO_APPLE_VERIFIER_TOKEN,
  ]) {
    assert.equal(output.includes(secret), false);
  }
});

test('a clean child exit is still a watchdog failure when Apple is enabled', () => {
  const children = [];
  const result = supervise({
    env: completeEnv,
    spawnProcess(command) {
      const child = new FakeChild(command);
      children.push(child);
      return child;
    },
    logger: () => {},
    setExitCode: () => {},
  });

  children[1].emit('exit', 0, null);
  assert.equal(result.exitCode, 1);
  assert.deepEqual(children[0].kills, ['SIGTERM']);
});

test('a Fly secret can materialize only a private mode-0600 runtime key', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'xsgo-apple-'));
  const target = path.join(directory, 'iap.p8');
  const privateKey = 'runtime-secret-fixture';
  const env = {
    ...completeEnv,
    APPLE_IAP_KEY_PATH: target,
    APPLE_IAP_PRIVATE_KEY_BASE64: Buffer.from(privateKey).toString('base64'),
  };
  await materializeRuntimeKey(env);

  assert.equal(await readFile(target, 'utf8'), privateKey);
  assert.equal((await stat(target)).mode & 0o777, 0o600);
  assert.equal(Object.hasOwn(env, 'APPLE_IAP_PRIVATE_KEY_BASE64'), false);
});

test('key material alone cannot turn incomplete Apple config into a watchdog', async () => {
  assert.equal(await materializeRuntimeKey({
    APPLE_IAP_PRIVATE_KEY_BASE64: Buffer.from('secret').toString('base64'),
  }), false);
});
