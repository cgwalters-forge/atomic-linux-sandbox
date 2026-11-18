// Promotion-only helper. The workflow still owns VM gates, current-main checks
// and release tags; a successful return means both signing and verification ran.
import { createHash, createPublicKey } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const COSIGN_VERSION = '3.1.4';
// From the v3.1.4 release's cosign_checksums.txt (linux/amd64).
export const COSIGN_SHA256 = '424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa';

export function run(command, args, env = process.env) {
  const result = spawnSync(command, args, {
    env, encoding: 'utf8', timeout: 120_000, maxBuffer: 8 * 1024 * 1024,
  });
  // Do not include arguments, environment or tool output in errors: this helper
  // runs with signing credentials. Callers must not enable shell tracing.
  if (result.error || result.status !== 0) {
    throw new Error(`${command.split('/').at(-1)} failed (${result.status ?? 'timeout/spawn error'})`);
  }
  return result.stdout;
}

export function installCosign(directory) {
  if (process.platform !== 'linux' || process.arch !== 'x64') {
    throw new Error('The pinned cosign binary requires linux/amd64');
  }
  const binary = join(directory, 'cosign');
  run('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '120',
    '--output', binary,
    `https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64`]);
  if (createHash('sha256').update(readFileSync(binary)).digest('hex') !== COSIGN_SHA256) {
    throw new Error('cosign release checksum mismatch');
  }
  chmodSync(binary, 0o700);
  return binary;
}

export function signAndVerify(cosign, reference, publicKey, env = process.env) {
  if (!/^[a-z0-9][a-z0-9.:/_-]*@sha256:[0-9a-f]{64}$/.test(reference)) {
    throw new Error('Signing requires a repository reference with an exact sha256 digest, not a tag');
  }
  if (!env.COSIGN_PRIVATE_KEY || !Object.hasOwn(env, 'COSIGN_PASSWORD')) {
    throw new Error('COSIGN_PRIVATE_KEY and COSIGN_PASSWORD must be configured');
  }
  if (env.COSIGN_REPOSITORY) {
    throw new Error('COSIGN_REPOSITORY must be unset: signatures must stay alongside the image');
  }
  // An older valid signature must not mask a mismatched current signing secret.
  const canonical = pem => createPublicKey(pem).export({ type: 'spki', format: 'der' });
  const derived = canonical(run(cosign, ['public-key', '--key', 'env://COSIGN_PRIVATE_KEY'], env));
  if (!derived.equals(canonical(readFileSync(publicKey)))) {
    throw new Error('Configured signing key does not match the candidate public key');
  }
  run(cosign, ['sign', '--yes', '--key', 'env://COSIGN_PRIVATE_KEY',
    '--new-bundle-format=false', '--use-signing-config=false', '--tlog-upload=false', reference], env);
  run(cosign, ['verify', '--key', publicKey, '--insecure-ignore-tlog=true', '--offline', reference], env);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let directory;
  try {
    if (process.env.GITHUB_REF !== 'refs/heads/main'
        || !['push', 'workflow_dispatch'].includes(process.env.GITHUB_EVENT_NAME)
        || process.env.GITHUB_REPOSITORY !== 'cgwalters-forge/atomic-linux-sandbox') {
      throw new Error('Signing is restricted to trusted main promotion');
    }
    const [reference, imageId] = process.argv.slice(2);
    if (process.argv.length !== 4
        || !/^ghcr\.io\/cgwalters-forge\/atomic-linux@sha256:[0-9a-f]{64}$/.test(reference)
        || !/^sha256:[0-9a-f]{64}$/.test(imageId)) {
      throw new Error('Usage: node scripts/sign-image.mjs repository@sha256:digest tested-config-digest');
    }
    const manifest = JSON.parse(run('skopeo', ['inspect', '--raw', `docker://${reference}`]));
    if (manifest.config?.digest !== imageId) {
      throw new Error('Registry manifest config differs from the VM-tested image');
    }
    directory = mkdtempSync(join(tmpdir(), 'atomic-linux-cosign-'));
    signAndVerify(installCosign(directory), reference,
      fileURLToPath(new URL('../custom/system/usr/share/atomic-linux/keys/cosign.pub', import.meta.url)));
    console.log(`Signed and verified ${reference}; no release tags changed.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    if (directory) rmSync(directory, { recursive: true, force: true });
  }
}
