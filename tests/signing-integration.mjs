// Isolated loopback registry only. No production credentials or image publication.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { installCosign, run, signAndVerify } from '../scripts/sign-image.mjs';

const directory = mkdtempSync(join(tmpdir(), 'atomic-linux-signing-test-'));
let registryProcess;
const env = { ...process.env, COSIGN_PASSWORD: '', DOCKER_CONFIG: join(directory, 'docker') };
for (const key of ['COSIGN_PRIVATE_KEY', 'COSIGN_REPOSITORY', 'GITHUB_TOKEN', 'GH_TOKEN', 'REGISTRY_AUTH_FILE']) delete env[key];
mkdirSync(env.DOCKER_CONFIG);
env.REGISTRY_AUTH_FILE = join(directory, 'auth.json');
writeFileSync(env.REGISTRY_AUTH_FILE, JSON.stringify({ auths: {} }));
const command = (tool, args) => {
  if (tool !== 'skopeo') return run(tool, args, env);
  const result = spawnSync(tool, args, { env, encoding: 'utf8', timeout: 120_000 });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};
const reject = (tool, args) => {
  const result = spawnSync(tool, args, { env, encoding: 'utf8', timeout: 120_000 });
  assert.equal(result.error, undefined);
  assert.notEqual(result.status, 0, 'verification unexpectedly accepted an untrusted image');
  assert.match(result.stderr, /signature|signatures|policy/i);
};

try {
  const cosign = installCosign(directory);
  // Reserve an available loopback port. The registry itself binds only loopback.
  const server = createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  const registry = `127.0.0.1:${port}`;
  // Native disposable registry avoids depending on nested-container privileges.
  const archive = join(directory, 'registry.tar.gz');
  command('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '120',
    '--output', archive,
    'https://github.com/distribution/distribution/releases/download/v3.1.2/registry_3.1.2_linux_amd64.tar.gz']);
  assert.equal(createHash('sha256').update(readFileSync(archive)).digest('hex'),
    '40df2224d410f72ae425c3371873b078bbdbda3b8b612be9571f0e6751f3acc8');
  command('tar', ['-xzf', archive, '-C', directory, 'registry']);
  const registryConfig = join(directory, 'registry.json');
  writeFileSync(registryConfig, JSON.stringify({ version: 0.1,
    storage: { filesystem: { rootdirectory: join(directory, 'storage') } },
    http: { addr: `127.0.0.1:${port}` }, log: { level: 'error' } }));
  // Distribution treats REGISTRY_* as its own settings, including skopeo's auth path.
  const registryEnv = Object.fromEntries(Object.entries(env).filter(([key]) => !key.startsWith('REGISTRY_')));
  registryProcess = spawn(join(directory, 'registry'), ['serve', registryConfig], { env: registryEnv, stdio: 'ignore' });
  registryProcess.on('error', () => {}); // Readiness failure below includes spawn failure.
  let ready = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      const response = await fetch(`http://${registry}/v2/`);
      if (response.ok) { ready = true; break; }
    } catch { /* registry still starting */ }
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  assert.ok(ready, 'loopback registry did not become ready');

  // Build a tiny valid OCI image locally, without pulling a base or running a build.
  const oci = join(directory, 'oci');
  mkdirSync(join(oci, 'blobs', 'sha256'), { recursive: true });
  const blob = value => {
    const data = JSON.stringify(value);
    const hash = createHash('sha256').update(data).digest('hex');
    writeFileSync(join(oci, 'blobs', 'sha256', hash), data);
    return { digest: `sha256:${hash}`, size: Buffer.byteLength(data) };
  };
  const image = marker => {
    const config = blob({ architecture: 'amd64', os: 'linux', config: { Labels: { marker } },
      rootfs: { type: 'layers', diff_ids: [] } });
    const manifest = blob({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.manifest.v1+json',
      config: { ...config, mediaType: 'application/vnd.oci.image.config.v1+json' }, layers: [] });
    writeFileSync(join(oci, 'oci-layout'), JSON.stringify({ imageLayoutVersion: '1.0.0' }));
    writeFileSync(join(oci, 'index.json'), JSON.stringify({ schemaVersion: 2, manifests: [{ ...manifest,
      mediaType: 'application/vnd.oci.image.manifest.v1+json', annotations: { 'org.opencontainers.image.ref.name': 'test' } }] }));
    return manifest.digest;
  };
  for (const tag of ['signed', 'unsigned']) {
    const digest = image(tag);
    command('skopeo', ['--insecure-policy', 'copy', '--dest-tls-verify=false', '--preserve-digests',
      `oci:${oci}:test`, `docker://${registry}/base:${tag}`]);
    if (tag === 'signed') env.TEST_SIGNED_DIGEST = digest;
  }
  for (const key of ['right', 'wrong']) {
    command(cosign, ['generate-key-pair', '--output-key-prefix', join(directory, key)]);
  }
  env.COSIGN_PRIVATE_KEY = readFileSync(join(directory, 'right.key'), 'utf8');
  const reference = `${registry}/base@${env.TEST_SIGNED_DIGEST}`;
  const right = join(directory, 'right.pub');
  const wrong = join(directory, 'wrong.pub');
  signAndVerify(cosign, reference, right, env);
  assert.throws(() => signAndVerify(cosign, reference, wrong, env), /does not match/);
  // An existing right-key signature must not hide a mismatched current secret.
  env.COSIGN_PRIVATE_KEY = readFileSync(join(directory, 'wrong.key'), 'utf8');
  assert.throws(() => signAndVerify(cosign, reference, right, env), /does not match/);
  env.COSIGN_PRIVATE_KEY = readFileSync(join(directory, 'right.key'), 'utf8');
  assert.throws(() => signAndVerify(cosign, reference, right,
    { ...env, COSIGN_REPOSITORY: 'registry.invalid/redirect' }), /must be unset/);
  reject(cosign, ['verify', '--key', wrong, '--insecure-ignore-tlog=true', '--offline', reference]);
  reject(cosign, ['verify', '--key', right, '--insecure-ignore-tlog=true', '--offline', `${registry}/base:unsigned`]);
  console.log('cosign: signed digest accepted; wrong key and unsigned image rejected');

  const registries = join(directory, 'registries.d');
  mkdirSync(registries);
  const config = readFileSync('docs/signing/registries.d/atomic-linux.yaml', 'utf8')
    .replace('ghcr.io/cgwalters-forge/atomic-linux', `${registry}/base`);
  writeFileSync(join(registries, 'test.yaml'), config);
  const policy = JSON.parse(readFileSync('docs/signing/policy.json'));
  const [requirement] = policy.transports.docker['ghcr.io/cgwalters-forge/atomic-linux'];
  policy.transports.docker = { [`${registry}/base`]: [requirement] };
  const policyPath = join(directory, 'policy.json');
  const copy = source => ['--registries.d', registries, '--policy', policyPath,
    'copy', '--src-tls-verify=false', `docker://${source}`, `dir:${join(directory, 'verified')}`];
  requirement.keyPath = right;
  writeFileSync(policyPath, JSON.stringify(policy));
  command('skopeo', copy(reference));
  reject('skopeo', copy(`${registry}/base:unsigned`));
  requirement.keyPath = wrong;
  writeFileSync(policyPath, JSON.stringify(policy));
  reject('skopeo', copy(reference));
  console.log('containers/image: policy parsed; signed digest accepted; unsigned and wrong key rejected');
} finally {
  if (registryProcess?.pid && registryProcess.exitCode === null) {
    const exited = new Promise(resolve => registryProcess.once('exit', resolve));
    registryProcess.kill('SIGTERM');
    const deadline = setTimeout(() => registryProcess.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(deadline);
  }
  rmSync(directory, { recursive: true, force: true });
}
