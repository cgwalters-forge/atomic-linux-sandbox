# Installing on hardware

> This text is LLM generated.

Nothing here has been run on hardware yet (see the README's status). The
commands follow bootc's documentation as of November 2026:
[installation](https://bootc.dev/bootc/bootc-installation.7.html),
[`install to-existing-root`](https://bootc.dev/bootc/man/bootc-install-to-existing-root.8.html),
[`install to-disk`](https://bootc.dev/bootc/man/bootc-install-to-disk.8.html)
and [`switch`](https://bootc.dev/bootc/man/bootc-switch.8.html).

Use `IMAGE` below for the image you install: usually a derived image (see
"Deriving an image" in the [README](../README.md)), or
`ghcr.io/cgwalters-forge/atomic-linux:stable` to try the desktop variant
(the server variant is not published yet). Images are
not signed yet. The image uses bootc's composefs backend only (see
"composefs only" in the README), so every install below is a fresh one.

On composefs, bootc ignores `--enforce-container-sigpolicy` and records the
image's origin as unverified; `/etc/containers/policy.json`, which is still
checked on every pull, is the only signature enforcement.

## Onto an existing Fedora machine: `bootc install to-existing-root`

This installs the image into the machine's current root filesystem. bootc
wipes `/boot`, reinitializes the `EFI/` and `loader/` directories of the EFI
system partition and writes a new boot entry. Everything else on the root
filesystem stays where it was, but the new system does not use it: the old
root is visible under `/sysroot` after reboot. The old operating system no
longer boots, so there is no rollback to it.

### Before you start

- Back up what you cannot lose. Other systems booted from the same EFI
  system partition (for example Windows in `EFI/Microsoft`) may lose their
  boot entries when `EFI/` is reinitialized.
- Run as root on the machine itself, with podman installed. The running
  kernel writes the new system, so it must support the existing storage
  (LVM, LUKS, btrfs subvolumes). A root in a btrfs subvolume, as Fedora
  Workstation creates it, has not been tried with this image.
- Have a second machine that can reach this one over SSH. The image enables
  `sshd`, and the firewall's default zone allows SSH; until you recreate
  your user, root's SSH keys are the way in.
- Note your user's name, UID and GID (`id`), and where `/home` lives
  (`findmnt /home`): a separate partition or btrfs subvolume (the Fedora
  Workstation default) is not mounted by the new system.

### Install

Pull the image into root's container storage, then run the installer from
it:

```sh
podman pull IMAGE
podman run --rm --privileged --pid=host \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v /:/target \
  --security-opt label=type:unconfined_t \
  IMAGE \
  bootc install to-existing-root \
    --root-ssh-authorized-keys /target/root/.ssh/authorized_keys
```

`--root-ssh-authorized-keys` copies root's current `authorized_keys` (the
host is mounted at `/target`) into the new system; put your key there first,
or point the option at another file under `/target`. bootc waits a few
seconds before it starts so you can abort; `--acknowledge-destructive`
skips that. Don't pass `--cleanup` if you need anything from the old root:
it deletes files from the previous install on the first boot, before you
can copy them. Reboot when it finishes.

### What survives

| Path | In the new system |
| --- | --- |
| `/boot` | Wiped and rewritten |
| `/etc` | Fresh from the image; the old one is at `/sysroot/etc` |
| `/var` | Fresh and empty except what the image creates; the old one is at `/sysroot/var` |
| `/home` | A link to `/var/home`, which starts empty |
| Old `/home` on the root filesystem | Still at `/sysroot/home` |
| Old `/home` on another partition or subvolume | Untouched and unmounted |

Nothing is migrated for you: users, passwords, network connections,
container images, Flatpaks and libvirt VMs all need copying or reinstalling.

### After the first boot

Log in as root over SSH with the key you carried, check `bootc status`, then
bring back your user and data:

```sh
# Recreate the user with the old UID and GID so file ownership still matches.
groupadd -g 1000 alice && useradd -M -u 1000 -g 1000 -G wheel alice
passwd alice
# Old home on the root filesystem: /sysroot is read-only, so copy it.
cp -a --reflink=auto /sysroot/home/alice /var/home/alice
restorecon -R /var/home/alice
```

The password is for local and sudo use: sshd accepts keys only, so keep an
`~/.ssh/authorized_keys` in the copied home for SSH.

If the old `/home` is a separate partition or subvolume, mount it at
`/var/home` instead, with a kernel argument (bootc's preferred way over
editing `fstab`). Pass it at install time:

```sh
bootc install to-existing-root ... \
  --karg=systemd.mount-extra=UUID=<fs-uuid>:/var/home:btrfs:subvol=home
```

`rpm-ostree kargs` does not work on composefs, so decide this before
installing.

Copy configuration you want from `/sysroot/etc` selectively, for example
NetworkManager profiles from
`/sysroot/etc/NetworkManager/system-connections/` (keep them mode 0600).
Don't copy generated files such as `resolv.conf`, and don't copy
`passwd`, `group` or `shadow` wholesale: the image keeps its system users in
`/usr/lib/passwd` and `/usr/lib/group`, and old entries would shadow them.
Anything every machine should have belongs in the derived image rather than
in `/etc`. When you have what you need, remove the old tree by hand after
`mount -o remount,rw /sysroot`, taking care to leave `/sysroot/composefs`,
`/sysroot/state` and `/sysroot/boot` alone.

## From Fedora Atomic or an ostree build: no `bootc switch`

Silverblue, Kinoite, other Fedora Atomic desktops and hosts installed from
an earlier (ostree) build of this image use bootc's ostree backend. They
must not `bootc switch`, `bootc upgrade` or `rpm-ostree rebase` onto this
composefs image in place; stop `bootc-fetch-apply-updates.timer` on hosts
that track it. They need a fresh install. `to-disk` below works from another
system; `to-existing-root` over an ostree host is not supported here yet,
and the steps above, written for a package-based Fedora, do not match its
layout (#68).

## Fresh disks: `to-disk` and ISOs

`bootc install to-disk` erases a whole disk and installs the image with a
btrfs root (this image's default). Run it from another system with the
target disk attached, as root:

```sh
podman run --rm --privileged --pid=host --ipc=host \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
  -v ./authorized_keys:/authorized_keys:ro \
  --security-opt label=type:unconfined_t \
  IMAGE \
  bootc install to-disk --root-ssh-authorized-keys /authorized_keys /dev/sdX
```

### Encrypted root with TPM2 unlock

`--block-setup tpm2-luks` puts the root in LUKS2 and binds its only key to
the TPM of the machine running the installer, so the system boots without a
passphrase. Run `to-disk` on the target machine itself, booted from live
media, since a disk prepared elsewhere is bound to the other machine's TPM.
The image permits this setup but keeps an unencrypted root as the default,
so the layout is always chosen by install options. bootc adds an
unencrypted 510 MiB `/boot` partition and the kernel arguments `luks.uuid=`
and `luks.options=tpm2-device=auto,headless=true`:

```sh
podman run ... IMAGE \
  bootc install to-disk --block-setup tpm2-luks --root-size 100G \
    --root-ssh-authorized-keys /authorized_keys /dev/sdX
```

`--root-size` leaves the rest of the disk unpartitioned for a data volume;
leave it out if the data goes on another disk. Two things to know about the
key bootc enrolls:

- There is no recovery key or passphrase. If the TPM is cleared, the
  firmware is reset or the board is replaced, the root cannot be unlocked.
- systemd 258 and later seal TPM2 keys to no PCRs by
  default. The TPM releases the key to anything booted on that machine, so
  this protects a disk removed from the machine (a failed or discarded
  drive), not a stolen machine.

After the first boot, as root, enroll a recovery key and keep it off the
machine, then optionally rebind the TPM key to the Secure Boot state
(PCR 7). That PCR usually stays the same across kernel and bootloader
updates but changes when the firmware's Secure Boot database is updated;
you then type the recovery key at the console once and repeat the
`--tpm2-pcrs=7` command.

```sh
dev=/dev/disk/by-uuid/$(sed -n 's/.*luks\.uuid=\([^ ]*\).*/\1/p' /proc/cmdline)
systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key "$dev"
systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 \
  --tpm2-device=auto --tpm2-pcrs=7 "$dev"
```

`headless=true` forbids the recovery prompt. `rpm-ostree kargs` does not
work on composefs; for the GRUB install above, edit the booted deployment's
entry in `/boot/loader/entries/`. Remount `/boot` read-write for the edit,
replace `luks.options=tpm2-device=auto,headless=true` with
`luks.options=tpm2-device=auto` on the `options` line, then remount `/boot`
read-only. Leave the other options intact. Bootc takes the booted entry's
arguments as the starting point for upgrades.

### Separate data volume

Put the encrypted volume for `/var/home` and VM and runner storage on a
second disk if you plan to reinstall the root. **`bootc install to-disk`
destroys all existing partitions on its target disk**, including a data
partition on that disk. Do not use `to-existing-root` from the installed
composefs host: its running root is read-only EROFS. This guide does not
cover a data-preserving reinstall with both volumes on the same disk.

Create the volume after the first boot and before creating users, since
mounting it hides whatever `/var/home` already holds. For a same-disk
volume, install with `--root-size` as above to leave free space. Run these
commands as root. Set `disk` to the whole install disk after confirming its
identity (for example, model and serial) and existing partitions with
`lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,MOUNTPOINTS`. Run
`sfdisk --list-free "$disk"` and confirm the expected free space before
appending a partition:

```sh
printf 'name=data\n' | sfdisk --append --no-reread --no-tell-kernel "$disk"
partx --show --bytes --output NR,START,SIZE,NAME "$disk"
```

Set `partno` to the number of the new `data` partition shown in the
expected free space. Add just that partition to the kernel's view rather
than rereading the whole table while the root partition is in use:

```sh
partx --add --nr "$partno" "$disk"
udevadm settle
lsblk --bytes -o NAME,PATH,TYPE,START,SIZE,PARTLABEL,MOUNTPOINTS "$disk"
```

Before formatting, confirm that `lsblk` shows the new, unmounted `data`
partition under the intended disk, with the start and size shown by
`partx` (both `START` columns use 512-byte sectors, while `sfdisk` uses
the disk's logical sector size). Set `DATA` to that partition's `PATH`, not
the whole install disk. For a separate disk, use `lsblk` to verify its
identity and set `DATA` to the unused, unmounted disk or partition you
intend to erase. In either case, check that `DATA` has no child devices
and that `wipefs --no-act "$DATA"` reports no existing signatures. If a
command fails or the device is missing or does not match, stop before
formatting.

Keep the recovery passphrase you set here:

```sh
cryptsetup luksFormat --type luks2 "$DATA" &&
uuid=$(cryptsetup luksUUID "$DATA") &&
cryptsetup open "$DATA" data &&
mkfs.btrfs -L data /dev/mapper/data &&
mount /dev/mapper/data /mnt &&
btrfs subvolume create /mnt/home /mnt/libvirt &&
umount /mnt &&
cryptsetup close data
```

For optional TPM unlock, run `systemd-cryptenroll --tpm2-device=auto
--tpm2-pcrs=7 "$DATA"`. Keep the passphrase even if enrollment succeeds.

Before rebooting, edit the `options` line of the booted entry as above.
Append these arguments, replacing `<uuid>` with the value of `$uuid`:

```text
luks.name=<uuid>=data
luks.options=<uuid>=headless=false
systemd.mount-extra=/dev/mapper/data:/var/home:btrfs:subvol=home
systemd.mount-extra=/dev/mapper/data:/var/lib/libvirt:btrfs:subvol=libvirt
```

The UUID-specific `luks.options=` lets systemd prompt for the data volume's
passphrase even if the root's unqualified options set `headless=true`.
If you enrolled a TPM key for the data volume, use
`luks.options=<uuid>=headless=false,tpm2-device=auto` instead. Neither
automatic TPM unlock nor passphrase prompting has been tested with this
layout. Check that both subvolumes are mounted after reboot
before running `restorecon -R /var/home /var/lib/libvirt` to set their
SELinux labels. Add a subvolume and a `systemd.mount-extra=` argument for
each further path, such as a CI runner's work directory. Keep a copy of the
arguments and check them after a composefs upgrade; persistence of these
hand-edited boot entries has not been verified.

Reattaching an existing data volume after a root reinstall has not been
tested. Back up the data, target only the root disk in `to-disk`, and do
not repeat the format steps on the data device. Supply the data-volume
arguments again, including the UUID-specific `luks.options=` (`--karg` at
install time or edit the new boot entry), and verify unlock and mounts
before use. A new `tpm2-luks` root install sets
`headless=true` again; review the recovery steps above. Recreate users
with their old UID and GID so the files' ownership still matches.

### Rehearsing with bcvk

bcvk's `to-disk` has no `--block-setup` option and its VM has no TPM, so it
cannot exercise `tpm2-luks`. It can rehearse the partition layout and the
image's install configuration in a disk image (not yet run with this
image):

```sh
bcvk to-disk --disk-size 20G --root-size 10G IMAGE /var/tmp/layout.img
sfdisk -l /var/tmp/layout.img
```

On x86_64 the result has a 1 MiB BIOS boot partition, a 512 MiB EFI system
partition and a 10 GiB root, with the rest of the disk free. `tpm2-luks`
adds the 510 MiB `boot` partition before the root.

### Installer ISOs

An installer ISO needs osbuild's
[image-builder](https://osbuild.org/docs/developer-guide/projects/image-builder/usage/#bootc)
`bootc-installer` type, which also needs an installer container image; this
repository does not provide one, and bootc-image-builder's `anaconda-iso` is
[being deprecated](https://osbuild.org/docs/bootc/deprecation-notice/).

## Secure Boot

The image keeps Fedora's kernel and its signed shim and GRUB, so it boots
with Secure Boot enabled and nothing to enroll. MOK enrollment
(`mokutil --import`) is only needed if a derived image adds kernel modules
signed with a key outside Fedora's chain, such as the Universal Blue akmods
that `build/40-nvidia.sh.example` installs; enroll the public key of whoever
signed them before switching to such an image, or the modules will not load.

## Updates and rollback

The installed system fetches and stages updates in the background and never
reboots for them; the next boot uses the staged image. See
[updates.md](updates.md) for applying, rolling back, pinning and turning
the timer off.
