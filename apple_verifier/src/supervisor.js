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
  let dartStopping = false;
  let appleStopped = false;

  const start = (role, name, command, args = []) => {
    const child = spawnProcess(command, args);
    const entry = {role, name, child, running: true};
    children.push(entry);
    const ended = (code, signal) => {
      if (!entry.running) return;
      entry.running = false;
      childStopped(entry, code, signal);
    };
    child.once('error', () => ended(78, null));
    child.once('exit', ended);
    return child;
  };

  const childStopped = (entry, code, signal) => {
    if (entry.role === 'apple') {
      if (dartStopping || appleStopped) return;
      appleStopped = true;
      logger(
        'Apple verifier stopped; Dart remains available and Apple verification stays fail-closed',
      );
      return;
    }
    if (dartStopping) return;
    dartStopping = true;
    const childCode = Number.isInteger(code) ? code : signal ? 1 : 78;
    const exitCode = childCode === 0 ? 1 : childCode;
    state.exitCode = exitCode;
    setExitCode(exitCode);
    logger('Dart server stopped; container supervisor exiting');
    for (const sibling of children) {
      if (sibling.role === 'apple' && sibling.running) {
        sibling.child.kill('SIGTERM');
      }
    }
  };

  start('dart', 'Dart server', '/app/server');
  if (mode === 'apple-enabled') {
    start('apple', 'Apple verifier', process.execPath, [
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
