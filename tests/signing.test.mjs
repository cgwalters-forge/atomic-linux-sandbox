import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPublicKey } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { signAndVerify } from '../scripts/sign-image.mjs';

test('reject mutable tags, malformed digests and missing signing secrets before invoking cosign', () => {
  for (const reference of ['ghcr.io/test:stable', `ghcr.io/test@sha256:${'a'.repeat(63)}`, '-bad']) {
    assert.throws(() => signAndVerify('/must-not-run', reference, 'key', {}), /exact sha256/);
  }
  assert.throws(() => signAndVerify('/must-not-run', `ghcr.io/test@sha256:${'a'.repeat(64)}`, 'key', {}), /must be configured/);
});

test('CLI refuses pull requests, merge groups, foreign repositories and non-main refs', () => {
  const trusted = {
    ...process.env, GITHUB_REF: 'refs/heads/main', GITHUB_EVENT_NAME: 'push',
    GITHUB_REPOSITORY: 'cgwalters-forge/atomic-linux-sandbox',
  };
  for (const override of [
    { GITHUB_EVENT_NAME: 'pull_request' }, { GITHUB_EVENT_NAME: 'pull_request_target' },
    { GITHUB_EVENT_NAME: 'merge_group' }, { GITHUB_REF: 'refs/pull/1/merge' },
    { GITHUB_REPOSITORY: 'someone/else' },
  ]) {
    const result = spawnSync(process.execPath, ['scripts/sign-image.mjs'], {
      env: { ...trusted, ...override }, encoding: 'utf8',
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /restricted to trusted main/);
  }
});

test('sign/verify failures propagate, and verification cannot be skipped after signing', () => {
  const directory = mkdtempSync(join(tmpdir(), 'signing-unit-'));
  try {
    const cosign = join(directory, 'cosign');
    const log = join(directory, 'calls');
    writeFileSync(cosign, `#!${process.execPath}
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.TEST_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');
if (process.argv[2] === 'public-key') process.stdout.write(process.env.TEST_PUBLIC_KEY);
process.exit(process.argv[2] === process.env.TEST_FAIL ? 1 : 0);
`);
    chmodSync(cosign, 0o700);
    const publicKey = 'custom/system/usr/share/atomic-linux/keys/cosign.pub';
    const env = { ...process.env, TEST_LOG: log, COSIGN_PRIVATE_KEY: 'mock-input', COSIGN_PASSWORD: '',
      TEST_PUBLIC_KEY: readFileSync(publicKey, 'utf8'), COSIGN_REPOSITORY: '' };
    const attempts = [
      ['public-key', ['public-key']], ['sign', ['public-key', 'sign']],
      ['verify', ['public-key', 'sign', 'verify']], ['', ['public-key', 'sign', 'verify']],
    ];
    for (const [failure, commands] of attempts) {
      writeFileSync(log, '');
      const call = () => signAndVerify(cosign, `ghcr.io/test@sha256:${'a'.repeat(64)}`, publicKey,
        { ...env, TEST_FAIL: failure });
      if (failure) assert.throws(call, /cosign failed/);
      else call();
      const calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
      assert.deepEqual(calls.map(args => args[0]), commands);
      const sign = calls.find(args => args[0] === 'sign');
      if (sign) {
        assert.ok(sign.includes('--new-bundle-format=false'));
        assert.ok(sign.includes('--use-signing-config=false'));
        assert.ok(sign.includes('env://COSIGN_PRIVATE_KEY'));
      }
    }
    assert.throws(() => signAndVerify(cosign, `ghcr.io/test@sha256:${'a'.repeat(64)}`, publicKey,
      { ...env, COSIGN_REPOSITORY: 'registry.invalid/redirect' }), /must be unset/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('policy is inactive, default-reject and scoped to the one image repository', () => {
  const policy = JSON.parse(readFileSync('docs/signing/policy.json'));
  assert.deepEqual(policy.default, [{ type: 'reject' }]);
  assert.deepEqual(Object.keys(policy.transports), ['docker']);
  assert.deepEqual(Object.keys(policy.transports.docker), ['ghcr.io/cgwalters-forge/atomic-linux']);
  assert.deepEqual(policy.transports.docker['ghcr.io/cgwalters-forge/atomic-linux'], [{
    type: 'sigstoreSigned', keyPath: '/usr/share/atomic-linux/keys/cosign.pub',
    signedIdentity: { type: 'matchRepository' },
  }]);
  assert.equal(readFileSync('docs/signing/registries.d/atomic-linux.yaml', 'utf8'),
    'docker:\n  ghcr.io/cgwalters-forge/atomic-linux:\n    use-sigstore-attachments: true\n');
  const key = createPublicKey(readFileSync('custom/system/usr/share/atomic-linux/keys/cosign.pub'));
  assert.equal(key.asymmetricKeyType, 'ec'); // Syntax only, not proof of secret matching.
});
