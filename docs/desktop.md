# Desktop operation

> This text is LLM generated.

The desktop is a thin GNOME/GDM variant of the shared base. It retains Flatpak,
power-profiles-daemon, toolbox and fwupd. `mesa-vulkan-drivers` explicitly
supplies Mesa RADV and `vulkan-loader` the Vulkan loader. Server remains headless;
none of the optional settings below is active in either default image.

## Rootless AMD Vulkan workloads

Identify the AMD render node with `ls -l /dev/dri/by-path/` and
`udevadm info /dev/dri/renderD128` (the number is not stable). The logged-in
user needs read/write access to that node, through a session ACL or the host's
render group. If adding group membership locally, log out and back in. Verify
with `test -r /dev/dri/renderD128 && test -w /dev/dri/renderD128`.

Use a trusted, digest-pinned container containing its **own** Vulkan loader,
Mesa RADV userspace, and llama.cpp built with `GGML_VULKAN=ON`; host RPMs do not
populate a container. First run `vulkaninfo --summary` in that same image and
verify an AMD/RADV device rather than lavapipe (software). Example, substituting
the node, image digest and model directory chosen locally:

```sh
podman run --rm --device /dev/dri/renderD128 --group-add keep-groups \
  -v "$HOME/models:/models:ro,Z" "$VULKAN_IMAGE" \
  llama-cli -m /models/model.gguf -ngl 99 -p 'Hello'
```

`keep-groups` needs crun and preserves supplementary host group access in a
rootless container. Pass only the render node, not all of `/dev` or the DRM card
node. Vulkan does not need `/dev/kfd` (that is a ROCm/HSA interface). Do not use
`--privileged`, `label=disable`, or `setenforce 0`. Keep SELinux enforcing.
The `:Z` mount labels a dedicated model directory for one container; do not
relabel a shared home directory. Use `:z` only when intentionally sharing models
among containers.

On Fedora, SELinux can deny device access even when Unix permissions allow it.
Inspect AVCs (`sudo ausearch -m AVC -ts recent`) first. If the denial is the
container-device policy, an administrator can opt into
`sudo setsebool -P container_use_devices on`. Record its previous value with
`getsebool container_use_devices`; restore it afterward (normally
`sudo setsebool -P container_use_devices off`). This broad boolean permits
container domains to use device labels; it is not specific to one GPU or
container. Prefer a reviewed local policy if that scope is unacceptable. Never
blindly generate policy from all AVCs. No policy exception ships in this image.

`tests/image/variant.sh` checks the installed Radeon ICD JSON and resolves its
`libvulkan_radeon.so` library. That is packaging validation, not proof of GPU
enumeration or inference. See [Mesa RADV](https://docs.mesa3d.org/drivers/radv.html)
and [Podman's device/group documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html).

## Optional TTM page limits at image build

Large GPU allocations may hit TTM's system-page limit. Raising it can exhaust
host RAM or cause OOMs; these are not recommended performance defaults and do
not guarantee usable VRAM. Select values in a downstream build for the actual
memory budget, leaving room for GNOME and other workloads.

`TTM_PAGES_LIMIT` and `TTM_PAGE_POOL_SIZE` are optional build arguments, also
forwarded by `just build`. Each accepts a canonical decimal page count from
`0` to `2147483647`; empty means omit that argument. Signs, whitespace, leading
zeroes (except `0`), units and expressions are rejected before writing anything.
This validation prevents extra kernel-argument/TOML injection, not unsafe memory
budgets. Zero is an explicit kernel value, not the opt-out. Counts are pages,
not bytes; inspect `getconf PAGESIZE` on the target. Consult the target kernel's
[TTM implementation](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/ttm/ttm_pool.c)
for parameter semantics, which can change with the kernel.

```sh
# Set these two variables to locally selected decimal page counts first.
TTM_PAGES_LIMIT="$chosen_pages" TTM_PAGE_POOL_SIZE="$chosen_pool" VARIANT=desktop just build tuned
TTM_PAGES_LIMIT="$chosen_pages" TTM_PAGE_POOL_SIZE="$chosen_pool" VARIANT=desktop just image-test tuned
```

The build writes `/usr/lib/bootc/kargs.d/60-ttm.toml` only if at least one value
is configured, using bootc's actual top-level TOML `kargs` array of strings,
such as `ttm.pages_limit=<selected count>` and
`ttm.page_pool_size=<selected count>`. There is no `[kargs]` table. Empty defaults
ship no drop-in. The mechanism works for either variant without adding a
desktop to server. Build and image-test must use the same inputs for a tag.

[bootc's kernel-argument documentation](https://github.com/bootc-dev/bootc/blob/main/docs/src/building/bootc-kernel-arguments.7.md)
specifies that image kargs apply at installation and image updates apply their
delta while preserving machine-local arguments. Rebuild, deploy with
`bootc upgrade`/`bootc switch`, then reboot: neither a running kernel nor editing
a build variable alone changes the limit. Verify `/proc/cmdline` and
`/sys/module/ttm/parameters/{pages_limit,page_pool_size}` on the booted target.
To revert, build with both arguments empty, deploy that image and reboot; bootc
removes the image-owned arguments. Alternatively roll back to the previous
deployment with `bootc rollback` and reboot. Do not locally delete image-owned
arguments with `rpm-ostree kargs`; upstream defines that interaction as undefined.
Separately added machine-local duplicates must be removed through the tool that
created them. Installed bootc update/removal behavior still needs a VM test here.

## Optional GNOME automatic-suspend override

Normal suspend is retained. For a host serving long workloads, the inactive
`custom/variants/desktop/no-auto-suspend.dconf` example sets GNOME's AC and
battery idle actions to `nothing`. This prevents idle automatic suspend, not
lid-close, explicit suspend, logind policy, or critical-battery shutdown. Leaving
a laptop awake on battery can drain it; do not store it running in a bag.

For **only the current user**, use GNOME Settings → Power → Automatic Suspend,
or run these inside that user's GNOME session:

```sh
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
```

Record the original two values. Restore them with `gsettings set`, or use
`gsettings reset` on each key to return to the system defaults. User changes
apply immediately but do not affect GDM or other users.

For **system defaults for users and the GDM greeter**, copy the example from
this checkout to both `/etc/dconf/db/local.d/60-no-auto-suspend` and
`/etc/dconf/db/gdm.d/60-no-auto-suspend` (create the directories with sudo first).
Ensure `/etc/dconf/profile/user` includes `user-db:user` then `system-db:local`,
and `/etc/dconf/profile/gdm` includes `user-db:user` then `system-db:gdm`.
Inspect and back up existing profiles; preserve other entries such as GDM's
vendor `file-db` fallback. Do not overwrite an existing profile or drop-in.
Run `sudo dconf update`, then log users out and back in; reboot to restart the
greeter without interrupting a live session. These are defaults, not locks:
existing user/GDM preferences take precedence. Reset those two keys in each
affected user's session if necessary. Check with `gsettings get` there; a root
shell reads root's settings, not a running user's or GDM's.

To reverse the system override, delete only those two `60-no-auto-suspend`
files, run `sudo dconf update`, restore profiles you modified from their backups,
and log out/reboot again. Restore/reset any user values changed separately.
The tests compile an isolated dconf database, check both keys, remove the
example and check the original defaults return; they do not observe an idle
GNOME session or GDM actually suspending.
See [GNOME's automatic-suspend administration guide](https://help.gnome.org/admin/system-admin-guide/stable/power-settings.html.en).

## MT7925 Wi-Fi: optional diagnostic workaround

The claim that MT7925 has an MLO regression on **all kernels 7.1+** is not
established by the authoritative sources checked on 2026-11-17. Upstream has
specific MLO fixes, including
[restoring legacy BSS after MLO teardown](https://git.kernel.org/linus/8f9e5807671ee97cacf1957f4a09e43f4f1017a9)
and [consistent MLD membership during link add](https://git.kernel.org/linus/dd3f17ef69ed6d0085cd94a15b9dec227b4ebfb1).
There is also a distinct [non-MLO handshake fix](https://git.kernel.org/linus/ac22c8c723c62013dd45b74e32249fc877c86fe0)
tested on MT7925U USB with kernel 7.2.3, not evidence of a universal PCIe/MLO
failure. Distribution backports, firmware, bus type and AP configuration matter;
no affected/fixed Fedora kernel range or hardware reproduction was verified here.
Record `uname -r`, firmware/kernel RPM versions and NetworkManager/kernel logs
before attributing a failure to MLO.

If an affected machine can use a 5 GHz AP, try a **local connection-profile**
restriction. This is a diagnostic workaround, not a proven MLO disable switch:
MLO can also operate within a band. NetworkManager documents `band=a` as 5 GHz
only, with driver-dependent support. It excludes 2.4/6 GHz and may lose coverage
or throughput. Use a local console: reactivation can disconnect SSH.

```sh
connection='replace with the local Wi-Fi connection name'
nmcli -g 802-11-wireless.band connection show "$connection"
sudo nmcli connection modify "$connection" 802-11-wireless.band a
sudo nmcli connection up "$connection"
```

Save the original band first. To restore an originally unrestricted profile:

```sh
sudo nmcli connection modify "$connection" 802-11-wireless.band ''
sudo nmcli connection up "$connection"
```

If it was restricted already, restore that recorded value instead. No connection,
device-specific module option or NetworkManager workaround is baked into the
image. See [NetworkManager's band reference](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html).

## Validation and integration boundaries

`just lint` runs build-input/TOML tests. `VARIANT=desktop just image-test` checks
package retention, enabled GDM, the installed RADV manifest/library, expected TTM
drop-in presence/content, and isolated dconf configuration/reversal. Boot the
image with `VARIANT=desktop just ephemeral-smoke` or the persistent VM recipes
for target/GDM activation; neither establishes interactive GNOME login, AMD
GPU inference or Wi-Fi reliability. Those require a real session and hardware.

The Flathub remote and the apps installed on first boot are described in
[Desktop Flatpaks](../README.md#desktop-flatpaks); no VM test confirms the
downloads. The runner stack belongs to
https://github.com/cgwalters-forge/atomic-linux-sandbox/pull/55 (open, unmerged
when checked). Its reported image and VM CI checks succeed on that PR's head,
not on this combined change; no runner changes are duplicated here. Validate
the merged stack separately before relying on desktop runner capacity.
