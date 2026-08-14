import {spawn} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

import {loadConfig} from './config.js';

export function runtimeMode(env) {
  try {
    loadConfig(env);
    return 'apple-enabled';
  } catch (_) {
    return 'dart-only';
  }
}

export async function materializeRuntimeKey(env) {
  if (runtimeMode(env) !== 'apple-enabled') return false;
  const encoded = `${env.APPLE_IAP_PRIVATE_KEY_BASE64 ?? ''}`.trim();
  if (encoded.length === 0) return false;
  const target = `${env.APPLE_IAP_KEY_PATH ?? ''}`.trim();
  if (target.length === 0 || !path.isAbsolute(target)) {
    throw new Error('runtime Apple key path must be absolute');
  }
  const decoded = Buffer.from(encoded, 'base64');
  if (decoded.length === 0 || decoded.toString('base64') !== encoded) {
    throw new Error('runtime Apple key is invalid');
  }
  await mkdir(path.dirname(target), {recursive: true, mode: 0o700});
  await writeFile(target, decoded, {mode: 0o600});
  delete env.APPLE_IAP_PRIVATE_KEY_BASE64;
  return true;
}

export function supervise({
  env,
  spawnProcess = (command, args) => spawn(command, args, {
    env,
    stdio: 'inherit',
  }),
  logger = (line) => process.stderr.write(`${line}\n`),
  setExitCode = (code) => {
    process.exitCode = code;
  },
} = {}) {
  const mode = runtimeMode(env ?? {});
  const state = {mode, exitCode: null};
  const children = [];
  let stopping = false;

  const start = (name, command, args = []) => {
    const child = spawnProcess(command, args);
    children.push({name, child});
    child.once('error', () => stop(name, 78, null));
    child.once('exit', (code, signal) => stop(name, code, signal));
    return child;
  };

  const stop = (name, code, signal) => {
    if (stopping) return;
    stopping = true;
    const childCode = Number.isInteger(code) ? code : signal ? 1 : 78;
    const exitCode = mode === 'apple-enabled' && childCode === 0
      ? 1
      : childCode;
    state.exitCode = exitCode;
    setExitCode(exitCode);
    logger(`${name} stopped; container supervisor exiting`);
    for (const entry of children) {
      if (entry.name !== name) entry.child.kill('SIGTERM');
    }
  };

  start('Dart server', '/app/server');
  if (mode === 'apple-enabled') {
    start('Apple verifier', process.execPath, [
      '/app/apple_verifier/src/server.js',
    ]);
  } else {
    logger('Apple verifier disabled; running Dart server only');
  }

  return state;
}

async function main() {
  await materializeRuntimeKey(process.env);
  supervise({env: process.env});
}

const invokedDirectly = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  main().catch((error) => {
    process.stderr.write(
      `Container supervisor failed to start: ${error?.name ?? 'Error'}\n`,
    );
    process.exitCode = 78;
  });
}
