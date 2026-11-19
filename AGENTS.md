# Working on atomic-linux

atomic-linux is a generic Fedora Atomic (bootc) desktop/host base image that
other images derive from; start with the [README](README.md). General agent
rules come from [cgwalters-forge/agenthome](https://github.com/cgwalters-forge/agenthome).

## Rules that matter here

- This repository is public. Nothing specific to one person or machine goes
  here: no hostnames, users, SSH keys, tailnet or VPN details, addresses,
  personal package lists or hardware tuning. Those belong in a derived image.
- Commit trailer exactly `Assisted-by: https://github.com/cgwalters/cgwalters#llms`;
  no `Signed-off-by`, no model names. Imperative subjects, the reason in the
  body. One task, one pull request.
- Never print or commit secrets. The build needs none; CI's only credential
  is the workflow's `GITHUB_TOKEN`, used only by the push and promote
  steps on `main`.
- Explain changes to workflows, permissions, action pins and pushed tags in
  the pull request. Non-`cgwalters-forge` actions are pinned by commit.

## Layout

- `Containerfile`: base image, context stage and the ordered `RUN` steps.
- `build/`: scripts run at build time from `/ctx`; `*.example` are inactive.
- `custom/system/`: files copied onto `/` by `build/10-build.sh`.
- `custom/brew`, `custom/flatpaks`, `custom/ujust`: user-facing examples.
- `tests/kubevirt/`: the nested-KVM acceptance fixture for `just kubevirt-test`.
- `.github/workflows/build.yml`: lint, image build, VM tests (`vm-smoke`,
  `vm-k3s`, `vm-lifecycle`) on PRs; on `main`, push as `git-<sha>` and
  promote that digest to `stable` once the VM tests pass.

## Build, lint and test

In CI order: `just lint-workflows` (needs a checkout of
cgwalters-forge/actions beside this one, `CONTAINER=podman` without docker),
`just lint`, then `just build`. Also run `just hadolint` and `just fmt-check`
after editing the Containerfile or Justfile. A full build pulls several GB
and needs about 30 GB of free disk. The VM recipes in the README need bcvk
and KVM; say which you ran in the pull request.

## Invariants

- The Containerfile ends with `bootc container lint --fatal-warnings`; keep
  it passing rather than relaxing it.
- k3s stays installed but disabled, and its modules and sysctls load only
  through `k3s-preflight.service`, so the image stays a normal desktop.
- Base and context images are pinned by tag, never by digest or `:latest`:
  registries drop old digests. Use the most specific tag that is immutable in
  practice (a date, a commit, a version) and let Renovate move it.
- The derivation hooks in the README (`write-image-info`, the k3s drop-in
  directory, `/etc/default/k3s-preflight`) are an interface for downstream
  images; change them only with a note in the README.
