> This text is LLM generated.

# atomic-linux

A generic [bootc](https://bootc-dev.github.io/) host image built on
[Fedora bootc](https://quay.io/repository/fedora/fedora-bootc), published as
`ghcr.io/cgwalters-forge/atomic-linux`. It is one image family: a shared
headless base plus two thin variants, **desktop** (GNOME, the default) and
**server** (headless). It is a base to derive from, not a finished personal system: what is specific
to one machine or person (users, SSH keys, network and VPN setup, hardware
tuning, extra packages) belongs in a small downstream image that starts
`FROM` this one.

It started as a [Universal Blue finpilot](https://github.com/projectbluefin/finpilot)
image and keeps finpilot's multi-stage layout and examples. Status: early.
The image builds and passes `bootc container lint`, and CI boots each
build of it with `just ephemeral-smoke` and the k3s VM check. The KubeVirt test passed on the
predecessor image but has not been rerun here, nothing has run on hardware,
and live image-signing acceptance is still pending; see [Image signing](docs/signing.md).

## What is in the image

The shared base, in both variants:

- Fedora bootc 45, digest-pinned, with Universal Blue's
  Homebrew integration (`brew-setup`, update and upgrade timers), a `ujust`
  launcher with host maintenance commands, and example Brewfiles.
  `@projectbluefin/common` is in the build context but not overlaid.
- `tmux` and `gum` (used by the ujust recipes); `podman.socket` enabled.
- Host services: `tailscaled` enabled but not logged in (`tailscale up`, tags
  and keys are left to the machine's owner), toolbox, chronyd, and `git`,
  `just`, `jq` and `curl`. No Node.js. `restic-backup.timer` runs a daily
  `restic backup` once both `/etc/restic-backup/env` (an `EnvironmentFile`
  with `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE` and any backend
  credentials) and `/etc/restic-backup/paths` (one path per line) exist;
  until then it does nothing. It uses `--one-file-system`, so list each
  mount or btrfs subvolume, and `/var/home` rather than the `/home` symlink.
  Pruning old snapshots is left to the owner.
- Debug tools for hosts that cannot easily rebuild: `strace`, `ltrace`,
  `perf`, `bpftrace` and `sysstat`. sysstat's periodic collection into
  `/var/log/sa` is preset off; `systemctl enable sysstat.service` turns it on.
- Cockpit web console and system, Podman, storage, NetworkManager and VM
  management pages, with `cockpit.socket` disabled (also by first-boot presets).
  No Cockpit firewall opening or VPN configuration is shipped. Access is a
  [downstream-only opt-in](docs/cockpit.md).
- `sshd.service` enabled, because bcvk's VM install waits for SSH. That is a
  real exposure, so firewalld governs it and sshd accepts keys only: password
  and keyboard-interactive login are off, and root may log in only with a key.
- Hardware support kept independent of the base's desktop package set
  (`custom/packages/hardware.txt`): linux-firmware plus its CPU microcode,
  GPU and NIC subpackages, NetworkManager with wifi, tpm2-tools,
  smartmontools (`smartd` enabled; it skips VMs) and fwupd.
  `fwupd-refresh.timer` is enabled, so every host periodically fetches LVFS
  metadata; it never applies firmware by itself.
- bootc's [composefs backend](#composefs-only), built from scratch with no
  ostree repository.
- `bootc-fetch-apply-updates.timer` enabled on composefs boots: it fetches
  and stages updates in the background without rebooting. The staged image
  takes effect on the next clean reboot; see [docs/updates.md](docs/updates.md).
- `bootc install` defaults to a btrfs root and allows a LUKS2 root unlocked
  by the TPM (`--block-setup tpm2-luks`, see [docs/install.md](docs/install.md)).
- Container short names are enforcing, with no search registries.
- firewalld enabled, and the default `FedoraWorkstation` zone (selected by
  the build, since fedora-bootc defaults to `public`) denies
  everything inbound apart from `ssh` and `tailscale` (UDP 41641, for direct
  tailnet connections), replacing Fedora's 1025-65535 tcp/udp opening.
  `dhcpv6-client` and `samba-client` are gone too, so stateful DHCPv6 and
  NetBIOS browsing need a derived image to add them back.
- k3s, checksum-pinned with k3s-selinux, **installed but disabled**. Its
  configuration (SELinux, secrets encryption, Flannel VXLAN, Traefik and
  ServiceLB off, NodePorts on loopback only, a `k3s` firewalld zone trusting
  only the pod and service CIDRs) and a preflight unit that loads the kernel
  modules and sysctls k3s needs only when k3s is enabled, so a host that
  never runs k3s is unaffected. `/usr/libexec/k3s-validate` is a bounded
  acceptance check for test VMs.
- `runner.slice`, a memory- and CPU-capped slice for CI runners and job
  VMs, unused until a unit opts in; see
  [Runner slice](#runner-slice).

The variants, chosen at build time with `VARIANT` (`build/40-variant.sh`):

- **server** boots to `multi-user.target` and adds nothing to the base.
- **desktop** adds a GNOME session (`custom/variants/desktop/`) and boots to
  GDM on `graphical.target`, with Mesa RADV/Vulkan userspace. See
  [Desktop operation](docs/desktop.md) for rootless GPU workloads and opt-in
  TTM build arguments, suspend settings and Wi-Fi diagnostics. It ships the
  system Flathub remote and a small Flatpak preinstall list, not installed
  apps; see [Desktop Flatpaks](#desktop-flatpaks).

Each variant's packages, files and units are drop-ins under
`custom/variants/<variant>/`, laid out like the base's `custom/packages`,
`custom/system` and `custom/units`.

## Desktop Flatpaks

Only the desktop drop-ins ship `/usr/share/flatpak/remotes.d/flathub.flatpakrepo`
(the [official Flathub definition](https://flathub.org/repo/flathub.flatpakrepo),
including its public verification key, with `CollectionID=org.flathub.Stable`
added to bind preinstalls before any metadata refresh). Flatpak discovers it
as the **system** remote `flathub`, URL `https://dl.flathub.org/repo/`, on first
use, even offline. Signature verification stays enabled. Fedora's remote
setup service remains masked and removed. No remote registration or app
downloads run during the build: final cleanup deletes `/var` state.

The desktop's `preinstall.d/default.preinstall` requests stable
`org.mozilla.firefox` and `org.gnome.Calculator` from that collection. The
server ships neither payload and stays headless. This does **not** promise
installed apps at first login: use the packaged command explicitly after
boot, when network access and download time are acceptable:

```sh
sudo flatpak preinstall --system --noninteractive
```

This downloads apps and their shared runtimes into `/var/lib/flatpak`, which
can take substantial space and time. On a fresh offline host the remote can
be discovered, but the apps cannot be downloaded; retry the command online.
No new background service or timer is enabled. See
[Flatpak preinstall integration](custom/flatpaks/README.md) for the checked
Fedora package interface, downstream overrides and runtime verification.

## Runner slice

`runner.slice` keeps CI runner workloads and their job VMs from starving the
host: a runaway job is throttled at `MemoryHigh=75%` of physical RAM and
OOM-killed inside the slice at `MemoryMax=85%`, rather than pushing sshd and
the other host services into the kernel's global OOM killer. `CPUWeight=50`,
half the default weight of its sibling slices, lowers its CPU share under
contention. Nothing runs in it until a unit opts in with
`Slice=runner.slice`, so a host without runners is unaffected.

The limits live in `/usr/lib/systemd/system/runner.slice.d/50-limits.conf`.
Override them with a later-sorting drop-in, in a derived image or on the
host, and check the result with `systemctl show runner.slice -p MemoryMax`:

```ini
# /etc/systemd/system/runner.slice.d/60-local.conf
[Slice]
MemoryHigh=24G
MemoryMax=28G
```

## Deriving an image

A downstream repository needs little more than this Containerfile:

```dockerfile
FROM ghcr.io/cgwalters-forge/atomic-linux@sha256:<digest>

ARG IMAGE_NAME=my-host
ARG IMAGE_VENDOR=me
ARG IMAGE_REGISTRY=registry.example.com/me
RUN /usr/libexec/atomic-linux/write-image-info

COPY system/ /
RUN dnf5 install -y <packages> && dnf5 clean all \
    && systemctl enable k3s.service

RUN bootc container lint --fatal-warnings
```

Pin the base by digest (take it from the build summary of the commit you
want, or `skopeo inspect docker://ghcr.io/cgwalters-forge/atomic-linux:stable`)
and bump it in its own pull request. [Verify the exact base digest before
`FROM`](docs/signing.md#verify-a-downstream-base-before-from) once signing and
trust bootstrap are validated. Configuration hooks:

| Hook | For |
| --- | --- |
| `/usr/libexec/atomic-linux/write-image-info` | Record the derived image's name and update origin in `image-info.json` |
| `/etc/rancher/k3s/config.yaml.d/*.yaml` | k3s settings; use `kubelet-arg+:` to add kubelet reservations without replacing the base list |
| `/etc/default/k3s-preflight` | `K3S_PREFLIGHT_REQUIRE_KVM=1` on KubeVirt hosts |
| `/etc/systemd/system/runner.slice.d/*.conf` | Runner memory and CPU limits; see [Runner slice](#runner-slice) |
| `/etc/modules-load.d/`, `/etc/modprobe.d/` | Hardware modules and options, e.g. `kvm_intel nested=1` |
| `/etc/ssh/sshd_config.d/` | sshd settings; a file sorting before `40-atomic-linux.conf` overrides the key-only defaults |

A derived image that installs packages should run `dnf5 clean all` (or reuse
this repository's `build/clean-stage.sh` pattern) so its own
`bootc container lint` passes.

## composefs only

The image uses bootc's
[composefs backend](https://bootc-dev.github.io/bootc/bootc-composefs.7.html)
only; there is no ostree build. The Containerfile uses the Fedora bootc image
as a builder: `bootc-base-imagectl build-rootfs` composes a fresh root from
the base's own `standard` manifest, the image starts `FROM scratch` with that
root, and our packages, drop-ins and variants go on top. It has no `/ostree`
link and no `/sysroot/ostree` repository, which the build checks before
`bootc container lint`. `build/15-bootc.sh` ships
`/usr/lib/composefs/setup-root-conf.toml`, removes ostree's
`prepare-root.conf` and regenerates the initramfs with bootc's `51bootc`
dracut module. `bootc install` (and so bcvk) then picks the composefs
backend by itself, with GRUB and BLS entries; no `--composefs-backend` flag is
needed. The root is a read-only, fs-verity-checked EROFS image, and `/etc` and
`/var` are per-deployment and shared state directories under `/sysroot/state`.

Building runs rpm-ostree in the builder stage, so `just build` passes
`--cap-add=all`, `--security-opt=label=disable` and `--device /dev/fuse` to
`podman build`. composefs needs bootc 1.17 or newer, and the build fails early
with older bootc. `BOOTC_SOURCE` picks where bootc comes from: `forge`, the
default for now, installs RPMs from a pinned, checksummed prerelease of the
[cgwalters-forge/bootc](https://github.com/cgwalters-forge/bootc) fork, which
carries fixes for `bootc install to-existing-root` that are pending upstream
(#68); `fedora` keeps the build root's Fedora bootc (1.17.1 or newer in
Fedora 45) and becomes the default again once Fedora ships those fixes;
`updates-testing` takes Fedora's newest build, and `copr` takes upstream's
main branch from the `rhcontainerbot/bootc` COPR:

```sh
just build                                 # bootc from the fork's release
BOOTC_SOURCE=fedora just build             # bootc from Fedora
BOOTC_SOURCE=copr just build               # bootc from upstream main
just composefs-vm-test stable              # install, stage, switch, roll back
```

`composefs-vm-test` installs the build in a disposable libvirt VM on a btrfs
root and checks that the update timer is active on a composefs boot. It
starts the update service directly and verifies that it stages the expected
image without rebooting, then reboots and checks that the image takes effect
and edits to `/etc` and `/var` survive. It also checks `bootc switch`,
`bootc rollback`, SELinux enforcement and the k3s preflight unit.

Both it and `to-existing-root-vm-test` print what started the installed
system (`bootctl status`, the LoaderInfo EFI variable, `bootc status`), the
Secure Boot state, the ESP's size and free space and the size of the shipped
kernel and initramfs. They require `bootc status` to report
`EXPECT_BOOTLOADER` (default `grub`) and the ESP to fit three deployments'
kernels, which a systemd-boot default would need.

**Moving from ostree.** An existing ostree host, including one installed
from an earlier ostree build of this image, must not `bootc switch` or
`bootc upgrade` onto it in place: bootc does not support that move and
nothing here tests it. Such a host should stop
`bootc-fetch-apply-updates.timer` and install fresh with `bootc install
to-disk` or `bootc install to-existing-root` (see
[docs/install.md](docs/install.md) and #68). `just to-existing-root-vm-test`
tests the second path in a disposable VM: from a Fedora bootc (ostree) host
with an ext4 `/boot` and a TPM-unlocked LUKS2 root holding btrfs in
`subvol=root`, it checks that the new system unlocks and boots composefs,
keeps `rd.luks.uuid` and the subvolume `rootflags`, and leaves the old
`/etc`, `/var` and home directory only under `/sysroot`.

The builder stage installs whatever Fedora 45's repositories carry at build
time; the base digest pins the build tools and manifest, not the packages.

**Signatures.** On composefs, bootc ignores
`--enforce-container-sigpolicy` and records the origin as unverified, but
the image is still pulled through containers/image, which checks
`/etc/containers/policy.json`. That file is the only signature enforcement:
a host or derived image that wants signed updates must require them there.
See [Image signing](docs/signing.md) for scoped opt-in examples, trust bootstrap
and the separate trust policy a derived image needs.

Known gaps, as of bootc 1.17.1 (October 2026):

- rpm-ostree, and so GNOME Software's OS updates, do not work. To stage an
  update without waiting for the timer, run `sudo bootc upgrade`, or use
  `ujust update-and-reboot` to stage and get a reboot prompt.
- With no separate `/boot` partition, systemd's GPT auto-generator mounts the
  ESP on `/boot` while the BLS entries and GRUB configuration live in
  `/sysroot/boot`, so `bootloader-update.service` (bootupd) fails on every
  boot and the system shows as degraded. Upgrades and rollback are unaffected.
- Upstream tests ext4 and XFS; btrfs, this image's default, is expected to
  work and passed the VM test here.
- No boot counting, logically bound images or `bootc edit`; see bootc's
  [known issues](https://bootc-dev.github.io/bootc/bootc-composefs.7.html#known-issues).

A derived image inherits the backend. If it changes bootc, it must also
regenerate the initramfs, which carries bootc's mount code.

## Transient /etc (test variant, opt-in)

`just build-transient-etc` builds `atomic-linux:transient-etc` with
composefs's transient `/etc` (`[etc] transient = true` in
`setup-root-conf.toml`, bootc-setup-root-conf.toml(5)): `/etc` is an overlay
whose upperdir is on tmpfs, reset on every boot. `ETC_MODE` defaults to
`persistent`; the normal image and stable promotion are unchanged. The build
verifies that the regenerated initramfs carries the same
`setup-root-conf.toml`.
`bootc container lint --fatal-warnings` remains mandatory.

With bcvk, libvirt and KVM, run `just transient-etc-vm-test`. This installs a
disposable VM, asserts a tmpfs-backed `/etc`, writes a marker, reboots and
asserts the marker disappeared. Unlike `bcvk ephemeral`, this actually
exercises bootc-root-setup.service. Only this variant includes the early audit
watch, `audit=1` and an audit-rules drop-in. It is measurement instrumentation,
not a security enforcement boundary; the test intentionally changes `/etc`.

The exercised scope is reaching the default target (and GDM activation on
the desktop variant, not interactive login), NetworkManager connection add/delete, a runtime firewalld port
change/revert, podman running a small remote image, timezone and hostname
changes, and enabling k3s through its existing preflight then running
`k3s-validate`. Each service step is bounded; failures remain visible findings.
The podman image is not pinned, so remote availability/content can affect
that exercise. No services are migrated in this phase.

`output/transient-etc-report.md` lists audit-observed operations, including
create-then-delete and rename endpoints absent from the final upperdir,
separately from the final upperdir inventory. Failed syscalls are attempts,
not successful writes; even a successful watched syscall can include an
unmodified operand. Upperdir-only paths, including parent copy-ups, are
unattributed. Relative dirfd paths remain unresolved, never matched by
basename. Writers show audit executable/comm/PID; service identity is unknown
unless recorded in the event as a unit or an unambiguous service cgroup.
No current PID lookup, parent-unit inference or executable-name mapping is
used. Standard syscall audit records often lack unit/cgroup evidence;
synthetic cgroup tests are not evidence of live service attribution.

The collector compares `SYSCALL items` with all `PATH` indexes (including
PARENT and null-name records). Partially missing rename/multi-path events,
duplicates and malformed item metadata are reported with event IDs and
expected/received items, rather than silently appearing complete. Acceptance
requires the early watch to be active/exited with a successful result, zero
exit status, a satisfied condition and a nonzero activation timestamp; a
working late watch alone cannot hide a failed/skipped early unit.
The report exposes audit lost/backlog counters and describes initramfs,
rule-reload and nested-mount gaps. It is not a complete census. A missing
watch, missing audit probe, or failed collector fails acceptance.

Diagnostics (install/exercise/collector logs, journal for both boots, raw
audit log and VM state) are collected best effort before cleanup beside the
report in `output/transient-etc-report-diagnostics/`, even after failure.
`KEEP_FAILED_VM=1` retains a failed VM. Reports identify candidates to move
to `/usr` or declarative configuration before considering a default change.

An unreachable guest, stuck SSH client or blocked libvirt operation must not
hang this test's failure path. Host-side `timeout` bounds each call and kills
clients still running two seconds after TERM. Positive integer second budgets
are `VM_CALL_TIMEOUT=120`, `INSTALL_TIMEOUT_SECS=1800`,
`EXERCISE_TIMEOUT_SECS=900`, `DIAGNOSTIC_TIMEOUT_SECS=30` (per diagnostic),
`CLEANUP_TIMEOUT_SECS=60` and `BOOT_WAIT_SECS=300`. Reboot polls use the
remaining reboot budget. These are test deadlines, not image security controls.
Diagnostics remain best effort; failed cleanup fails an otherwise successful
test but never replaces the original failure status. Final acceptance is
reported only after cleanup. Killing an install/client may leave guest-side
work or a VM behind; cleanup is attempted even after a failed install, and
cleanup failures are reported rather than claimed as removal.

Status: the variant and this installed-VM test exist, and `just lint` runs
the collector's synthetic tests, but nothing has booted the variant yet.
Producing a report needs a separate, non-gating workflow that builds the
variant and runs this test on a hosted runner with KVM; it has not been added.
CI does not exercise this variant. Draw no
conclusions about machine-id or installer configuration behavior until a
measured report is linked here.

## Utah variant (experimental)

`just build-utah` builds `atomic-linux:utah` from `Containerfile.utah`:
Project Bluefin's [Utah](https://github.com/projectbluefin/utah), a GNOME
workstation on Red Hat's Hummingbird packages, plus our host pieces from
`build/utah.sh`. Those are k3s (installed but disabled, with its preflight,
configuration and firewalld zone), the locked-down `FedoraWorkstation` zone
as the default in place of Utah's `lax`, the `bootc install` configuration,
key-only sshd settings, the composefs-native setup and `image-info.json`.
`sshd.service` stays disabled by default, so the image does not open an SSH
listener on TCP port 22. Utah's preinstall service adds the
[#80 Flathub apps](build/utah.preinstall) alongside its existing Flatpaks on
first boot; the apps are not baked into the image.

Utah keeps its own bootc (1.17.4, without the fork's `to-existing-root`
fixes) and ships Universal Blue's `uupd` updater with Dakota's systemd units
and hardware checks. The daily `uupd.timer` runs at 04:00; Utah also ships
triggers for resume and connecting AC power. `uupd` uses `bootc upgrade`
to stage an OS deployment for the next reboot without rebooting the
machine. Utah masks `bootc-fetch-apply-updates.timer` and its service; it
does not use the default image's update timer or drop-in.

Unlike the default image's base and context images, Utah is pinned by its
dated `testing-YYYYMMDD-<sha7>` tag, not a digest. The default image does not
change. Run `COMPOSEFS_TEST_UPDATE_SERVICE=0 just composefs-vm-test utah`
to test the lifecycle with a manual upgrade, or `just k3s-vm-create utah`
to create the k3s test VM. Enable sshd in a disposable derivative for these
SSH-based tests, as the Utah VM jobs do.

Status: it builds and passes `bootc container lint` (November 2026). CI's
`image-utah` and `vm-utah-*` jobs build it and run the default image's VM
suites on it (as the desktop variant) on pull requests and by hand; they are
not required for a merge,
the image is not pushed, and `vm-utah-to-existing-root` is allowed to fail.

## Build and test

```sh
just build          # the desktop variant, into containers-storage as atomic-linux:stable
just image-test     # run tests/image/*.sh in the built image with podman run
VARIANT=server just build server          # the server variant, as atomic-linux:server
VARIANT=server just image-test server     # test recipes take the same VARIANT
just lint           # shellcheck over the scripts
just hadolint       # Containerfile lint, in a container
just fmt-check      # Justfile formatting
```

With [bcvk](https://github.com/bootc-dev/bcvk) and rootless libvirt
(`qemu:///session`):

```sh
just ephemeral-smoke                       # stateless boot: identity, network, target
just vm-create && just vm-test             # persistent VM on a btrfs root
just k3s-vm-create && just k3s-vm-test     # enables k3s in the VM, runs k3s-validate
just kubevirt-test                         # nested KVM: disposable VM, KubeVirt L2 guest
```

`kubevirt-test` needs nested virtualization on the machine running it and
removes the VM it creates; `KEEP_FAILED_VM=1` keeps a failed one.

## Release

[.github/workflows/build.yml](.github/workflows/build.yml) builds every pull
request and boots the result in two VM jobs on a GitHub-hosted runner with
KVM and a pinned bcvk: `vm-smoke` runs `just ephemeral-smoke`, and `vm-k3s`
runs `just k3s-vm-create` and `just k3s-vm-test`. Both test the build job's
saved image, checked by image ID, not a rebuild; `vm-k3s` installs it with a
one-file layer on top, as `just composefs-vm-test` does. KubeVirt (`just
kubevirt-test`) needs nested KVM inside the test VM and is not run in CI.

A push to `main` pushes the image to `ghcr.io/cgwalters-forge/atomic-linux`
as `git-<sha>` only. Once both VM jobs pass, the `promote` job retags that
digest as the version label (`45.YYYYMMDD`) and `stable`, after checking
that its config is the image the VM jobs booted; nothing is rebuilt. A
failed VM test leaves `stable` where it was, and `promote` skips a build
that is no longer the head of `main`. The workflow's
`GITHUB_TOKEN` (`packages: write`) authenticates registry pushes, and the job
summaries print the digest. The pending signing integration uses only the existing
`COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD`, restricted to trusted main promotion;
the build and PR jobs must never receive them. Dependabot proposes digest bumps for the `FROM`
lines and action pins.

CI builds, tests and publishes only the default desktop variant so far, so
`stable` and the version tags stay a GNOME desktop. The server variant is not
published yet; building it in CI, with its own tags and promotion, is still
to do.

Signing preparation (a pinned cosign helper, candidate public key and inactive
verification examples) is documented in [docs/signing.md](docs/signing.md).
Workflow integration remains blocked on per-variant promotion and permission to
edit the workflow. No live key match or promoted-digest verification is claimed.

## License

Apache-2.0, see [LICENSE](LICENSE). Derived from the Universal Blue finpilot
template; see [NOTICE](NOTICE) for attribution.

Generated-by: https://github.com/cgwalters/#llms
