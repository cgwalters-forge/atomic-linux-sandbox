# Image signing

> This text is LLM generated.

## Status and threat

Digest pinning alone does not authenticate whoever supplied the digest. An
attacker able to replace a registry tag or a downstream digest suggestion could
otherwise substitute an image. Key-based cosign verification rejects images not
signed by the bootstrapped key. It does not stop a compromised signing job/key,
rollback to an older signed digest, or a malicious build accepted by CI.
Enforcement is **off by default**: no global policy or registries configuration
is installed by this change.

This is a dependent draft, not a signed-release announcement. Per-variant
promotion is still pending in
[the prerequisite](https://github.com/cgwalters-forge/atomic-linux-sandbox/issues/38).
The current workflow still publishes only desktop and has not been changed:
this run cannot edit protected `.github/` paths. The signing helper is not yet
wired into promotion. Existing releases must not be assumed signed.

The shipped `custom/system/usr/share/atomic-linux/keys/cosign.pub` is the
**candidate** supplied in
[this comment](https://github.com/cgwalters-forge/atomic-linux-sandbox/issues/46#issuecomment-6930043979),
not authenticated proof of the configured secrets' public half. No repository
secret was inspected or exercised here. Before trusting it, an authorized main
promotion must sign with the existing `COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD`
and verify with this exact public key. Independent operator confirmation of its
fingerprint is still needed for downstream trust bootstrap; fetching a key from
the same untrusted image or registry is not a trust bootstrap.

## Promotion integration still required

`node scripts/sign-image.mjs IMAGE@sha256:DIGEST TESTED_CONFIG_DIGEST` downloads
cosign **v3.1.4**, checks the linux/amd64 binary's SHA-256 against the pinned
release checksum, checks the remote manifest config, derives and compares the
configured key's public half to the candidate, signs the exact digest and
verifies it with the candidate key. It exits nonzero on failure; it never moves
release tags. Each subprocess has a two-minute deadline. The helper is specific
to this repository and rejects PR/merge-group events and non-main refs. These
environment checks are defense in depth, not a replacement for workflow job
conditions and secret isolation.

After variant CI lands, the workflow owner must insert this call for **each**
variant after successful VM/config-digest gates and the current-main guard,
before **any** version/stable/compatibility alias advances. Do not derive the
digest from a mutable tag or rebuild it. Recheck current main before advancing
tags if signing separates that check from retagging. Keep stable last, including
the unqualified desktop compatibility alias. Fail the promotion job if either
signing or verification fails or is skipped; never use `continue-on-error` or an
`always()` retag step. The aggregate main check must include promotion, with a
stale-main no-op distinguished from a skipped/failed signing step.

Only trusted main promotion may receive the two existing signing secrets; never
image/VM jobs or PR jobs. The caller must authenticate cosign's Docker config
and skopeo's registry auth using the existing `GITHUB_TOKEN`, without printing
it, and remove temporary auth files on failure too. No new credential,
`id-token: write`, or permission expansion is needed: retain `contents: read`
and promotion's existing `packages: write`. The key is read through
`env://COSIGN_PRIVATE_KEY`, not written to disk. Do not enable tracing or print
the environment. The helper deliberately does not publish to the transparency
log (`--tlog-upload=false`); verification uses key/digest/identity checks with
`--insecure-ignore-tlog=true --offline`, not a transparency-log inclusion claim.
It rejects `COSIGN_REPOSITORY` overrides so attachments cannot be redirected away
from the image repository. Comparing the public half before signing prevents
an old valid signature from masking a mismatched current signing secret.

Signing uses `--new-bundle-format=false --use-signing-config=false` to publish
legacy `sha256-<digest>.sig` attachments understood by containers/image, rather
than cosign v3's new bundle format. Those signature tags are separate from the
git, version and stable release tags. Registry garbage collection must preserve
them. No new action pin is introduced; the helper checks the binary checksum
before executing it. The checksum comes from the
[v3.1.4 release](https://github.com/sigstore/cosign/releases/tag/v3.1.4).

## Verify a downstream base before FROM

First authenticate the public key out of band and install it in the build
environment; do not take it from the image being verified. Resolve a promoted
variant to an immutable digest, then verify **that same reference** before
starting a build:

```sh
image=ghcr.io/cgwalters-forge/atomic-linux@sha256:<promoted-digest>
cosign verify --key /trusted/atomic-linux.pub --insecure-ignore-tlog=true --offline "$image"
```

Only after success use exactly that digest in `FROM`, not the tag just resolved.
Run verification as a required, fail-closed build step on every digest bump.
The current exact image scope is `ghcr.io/cgwalters-forge/atomic-linux` (desktop:
`stable`, `45.YYYYMMDD`, `git-<sha>`). The prerequisite proposes desktop/server
**tags within that same repository**, not separate image repositories. Confirm
its final tag spelling before enabling server consumers. Both variants therefore
use the same exact policy scope; there is no `ghcr.io/cgwalters-forge/*` wildcard.
Repository signatures do not distinguish desktop and server tags: obtain each
variant's digest from trusted CI metadata, not merely any signed digest in this
repository. New repositories require explicit new scopes, not a broadened prefix.

## Optional containers/image and bootc enforcement

`docs/signing/policy.json` is a standalone, default-reject policy for explicit
base-image verification. `docs/signing/registries.d/atomic-linux.yaml` enables
sigstore attachment discovery only for this image repository. Neither is copied
over `/etc/containers/policy.json` or installed globally. For an isolated check,
copy the registries.d example to a private directory, replace the example
policy's `keyPath` with the absolute path of the authenticated key, then run:

```sh
skopeo --registries.d /private/registries.d --policy /private/policy.json \
  copy "docker://$image" dir:/private/verified-image
```

`skopeo inspect` alone does not enforce this policy; a successful copy does.
The destination and configuration directory should be new temporary directories.
Use a small disposable image for negative tests; copying the real bootc image
requires several GB. Wrong-key and unsigned images must fail, not fall back to
`insecureAcceptAnything`.

A host opting into containers/image enforcement should merge only the exact
base-image `docker` scope into its existing policy, preserving unrelated trust
rules, and install the scoped registries.d entry. Review all existing
more-specific scopes for bypasses. Do not replace global policy with this
default-reject example blindly. On composefs, bootc ignores
`--enforce-container-sigpolicy` and records an unverified origin; enforcement is
through containers/image's policy on pull. Test the installed bootc version's
actual upgrade path before relying on it.

A derived image needs its **own** signing key and enforcing scope for updates.
Do not require the base key on the derived repository: the base signature does
not authenticate the derived layers. Verifying the base before `FROM` and
verifying downstream updates are separate trust decisions.

## Acceptance and rotation limitations

`node --test tests/signing.test.mjs` covers input restrictions and shipped policy
shape. `node tests/signing-integration.mjs` exercises a loopback-only disposable
registry with runtime-generated keys, a tiny synthetic image, positive cosign
and containers/image checks, and wrong-key/unsigned rejection. It neither uses
repository secrets nor publishes images externally. It is not live acceptance.
This passed in the isolated Linux runner on 2026-11-17 with cosign v3.1.4,
skopeo 1.21.0-dev and the checksum-pinned native Distribution v3.1.2 registry.
The registry listens only on loopback and its temporary data/keys are removed.
Nested Podman could not start containers in this runner, so this test uses a
native disposable registry process rather than a container. Workflow lint and
containerized hadolint were attempted but blocked by that runtime failure.

Live evidence is still missing: successful signing with configured secrets and
this candidate public key, followed by **separate** cosign verification and
containers/image policy-enforced copy of each real promoted variant digest.
Record the run URL, exact digest, key fingerprint, tool versions and each
verification result when an authorized promotion makes signatures available.
Do not trigger credential-bearing workflows solely to fill this gap.

Key rotation/revocation is manual. Authenticate a replacement out of band,
update downstream trust before removing the old key, and test new signatures
with both clients. Multiple policy requirements mean AND, not alternative keys;
do not model rotation as two required signatures unless that is intended.
Retained old signatures still validate against retained old keys; there is no
automatic expiry, revocation or freshness/rollback protection in this example.
