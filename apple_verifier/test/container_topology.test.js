import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const repositoryRoot = path.resolve(import.meta.dirname, '../..');

test('container pins Node 22 and exposes only the existing Dart port', async () => {
  const dockerfile = await readFile(path.join(repositoryRoot, 'Dockerfile'), 'utf8');
  assert.match(dockerfile, /FROM node:22-bookworm-slim/);
  assert.match(dockerfile, /EXPOSE 8091/);
  assert.doesNotMatch(dockerfile, /EXPOSE[^\n]*9000/);
  assert.match(dockerfile, /CMD \["node", "\/app\/apple_verifier\/src\/supervisor\.js"\]/);
});

test('Fly remains on Dart 8091 with the reviewed 512 MB declaration', async () => {
  const fly = await readFile(path.join(repositoryRoot, 'fly.toml'), 'utf8');
  assert.match(fly, /internal_port = 8091/);
  assert.match(fly, /memory = '512mb'/);
  assert.match(fly, /memory_mb = 512/);
  assert.doesNotMatch(fly, /9000/);
});

test('Docker build context excludes runtime Apple private keys', async () => {
  const dockerignore = await readFile(
    path.join(repositoryRoot, '.dockerignore'),
    'utf8',
  );
  assert.match(dockerignore, /^\.env$/m);
  assert.match(dockerignore, /^\*\.p8$/m);
  assert.match(dockerignore, /^\*private\*key\*$/m);
});
