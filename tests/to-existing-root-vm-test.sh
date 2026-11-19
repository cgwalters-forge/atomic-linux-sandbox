#!/usr/bin/bash
# Moving an ostree host to this image in a disposable libvirt VM. The start
# host is Fedora's ostree-based bootc image on a Fedora Atomic desktop's
# layout: GPT with BIOS boot and an ESP, an ext4 /boot, and a LUKS2 root
# unlocked by the VM's TPM holding btrfs mounted with rootflags=subvol=root.
# With markers in its /etc, /var and a home directory, it runs `bootc install
# to-existing-root --composefs-backend` with IMAGE and reboots. The new
# system must unlock and reach multi-user.target, keep rd.luks.uuid and the
# subvolume rootflags, boot the composefs backend, and show the markers only
# in the old stateroot under /sysroot.
#
# Usage: to-existing-root-vm-test.sh IMAGE (e.g. localhost/atomic-linux:stable)
# Environment: BCVK, BCVK_CONNECTION, PODMAN, START_IMAGE; KEEP_FAILED_VM=1
# keeps a failed VM for debugging. Needs qemu-img and virsh.

set -euo pipefail

image="${1:?usage: $0 IMAGE}"
# shellcheck source=tests/libvirt-vm.sh
source "$(dirname "$0")/libvirt-vm.sh"

# x86_64 fedora-bootc:45, ostree-based; it has cryptsetup, the TPM2 token
# plugin in its initramfs, podman and jq.
START_IMAGE="${START_IMAGE:-quay.io/fedora/fedora-bootc:45}"
readonly MARKER=/usr/share/atomic-linux-to-existing-root-test
readonly OLD_MARKER=atomic-linux-old-marker
readonly OLD_HOME=/var/home/atomic-linux-test
readonly HOST_STORAGE=/run/host-container-storage

run_id=$(< /proc/sys/kernel/random/uuid)
VM_NAME="atomic-linux-to-existing-root-${run_id:0:8}"
test_repo="localhost/atomic-linux-to-existing-root-test-${run_id:0:8}"
work=$(mktemp -d)
created=0
built_ids=()

cleanup() {
	status=$?
	if ((status != 0 && ${KEEP_FAILED_VM:-0} == 1)); then
		printf 'Retaining failed VM %s, its images %s:* and %s\n' "${VM_NAME}" "${test_repo}" "${work}" >&2
		exit "${status}"
	fi
	if ((created)); then
		"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" rm --force "${VM_NAME}" || status=1
	fi
	if ((${#built_ids[@]})); then
		"${PODMAN}" rmi --force --ignore "${built_ids[@]}" >/dev/null || status=1
	fi
	rm -rf "${work}"
	exit "${status}"
}
trap cleanup EXIT

# Unsigned local builds: bcvk and bootc then install them from the host's
# storage without a registry or signature checks.
derive() {
	local id
	id=$(derive_image "$1" "$2" "${MARKER}" "${test_repo}:$2")
	built_ids+=("${id}")
}

# Runs as root in an ephemeral VM of the start image, with the target disk
# attached and the host's storage at /run/virtiofs-mnt-hoststorage. The
# first boot unlocks root with a key file on /boot; the test enrolls the
# TPM and removes it.
make_start_disk() {
	local image=$1 luks_uuid=$2 boot_uuid=$3 root_uuid=$4 disk=/dev/disk/by-id/virtio-target
	set -euxo pipefail
	# As bcvk to-disk does: the inner podman needs writable storage and
	# a /var/tmp on the same filesystem.
	mount -t tmpfs -o size=4G tmpfs /var/tmp
	mkdir /var/tmp/containers
	rm -rf /var/lib/containers
	ln -sr /var/tmp/containers /var/lib/containers
	# bootupd installs GRUB for BIOS too on x86_64, which needs a BIOS boot
	# partition, as on Fedora's own bootc disk layouts.
	printf 'label: gpt\nsize=1MiB, type=21686148-6449-6E6F-744E-656564454649\nsize=512MiB, type=U\nsize=1GiB, type=L\ntype=L\n' | sfdisk --quiet "${disk}"
	udevadm settle
	mkfs.fat -F 32 -n EFI-SYSTEM "${disk}-part2"
	mkfs.ext4 -q -L boot -U "${boot_uuid}" "${disk}-part3"
	head -c 64 /dev/urandom >/run/luks.key
	cryptsetup luksFormat --batch-mode --type luks2 --uuid "${luks_uuid}" --key-file /run/luks.key "${disk}-part4"
	cryptsetup open --key-file /run/luks.key "${disk}-part4" root
	mkfs.btrfs -q -L fedora -U "${root_uuid}" /dev/mapper/root
	mkdir /run/top /run/target
	mount /dev/mapper/root /run/top
	btrfs subvolume create /run/top/root
	umount /run/top
	mount -o subvol=root /dev/mapper/root /run/target
	mkdir /run/target/boot
	mount "${disk}-part3" /run/target/boot
	mkdir /run/target/boot/efi
	mount "${disk}-part2" /run/target/boot/efi
	# console=ttyS0 is for the start host only, so its kernel reaches the
	# serial log; the new system's does only if to-existing-root keeps it.
	export STORAGE_OPTS=additionalimagestore=/run/virtiofs-mnt-hoststorage
	podman run --rm --privileged --pid=host --net=none --env=STORAGE_OPTS \
		-v /run/virtiofs-mnt-hoststorage:/run/virtiofs-mnt-hoststorage \
		-v /var/lib/containers:/var/lib/containers -v /var/tmp:/var/tmp -v /dev:/dev \
		-v /run/target:/target --security-opt label=type:unconfined_t "${image}" \
		bootc install to-filesystem --generic-image --skip-fetch-check \
		--karg "rd.luks.uuid=${luks_uuid}" \
		--karg "rd.luks.key=${luks_uuid}=/luks.key:UUID=${boot_uuid}" \
		--karg rootflags=subvol=root --karg console=ttyS0,115200n8 /target
	# The install is left exactly as bootc finalizes it, which includes
	# remounting /boot read-only; reopen it only to add the key file, as an
	# installer adds files after its payload.
	mount -o remount,rw /run/target/boot
	install -m 0400 /run/luks.key /run/target/boot/luks.key
	umount -R /run/target
	cryptsetup close root
}

# Checks that each line of $2 (kernel command lines) unlocks and mounts root.
expect_root_kargs() {
	local what=$1 line found=0
	while read -r line; do
		[[ -n "${line}" ]] || continue
		found=1
		if [[ ! " ${line} " =~ \ rd\.luks\.uuid=(luks-)?${luks_uuid}\  ]]; then
			echo "error: bootc bug: ${what} lacks rd.luks.uuid=${luks_uuid}, so root cannot be unlocked: ${line}" >&2
			return 1
		fi
		if [[ ! " ${line} " =~ \ rootflags=([^ ]*,)?subvol=/?root(,[^ ]*)?\  ]]; then
			echo "error: bootc bug: ${what} lacks rootflags=subvol=root, so root mounts the wrong subvolume: ${line}" >&2
			return 1
		fi
	done <<<"$2"
	if ((!found)); then
		echo "error: no kernel command line found in ${what}" >&2
		return 1
	fi
}

# Runs as root in the VM. Prints each BLS entry as its path, a tab and its
# options: the composefs backend may write them to the /boot partition, the
# physical root's /boot (/sysroot/boot on an ostree host) or the ESP. Also
# names any UKI and GRUB's bootuuid.cfg, which says where GRUB reads entries.
list_boot_entries() {
	local esp=/run/atomic-linux-esp f
	mkdir -p "${esp}"
	if ! mount -o ro "$(lsblk -nrpo PATH,PARTTYPE | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }')" "${esp}"; then
		echo "warning: could not mount the ESP" >&2
	fi
	for f in /boot/loader/entries*/*.conf /sysroot/boot/loader/entries*/*.conf "${esp}"/loader/entries*/*.conf; do
		[[ -f "${f}" ]] && printf '%s\t%s\n' "${f}" "$(sed -n 's/^options[[:space:]]*//p' "${f}")"
	done
	for f in "${esp}"/EFI/Linux/*.efi "${esp}"/EFI/*/bootuuid.cfg; do
		[[ -f "${f}" ]] && printf '%s\t%s\n' "${f}" "$([[ "${f}" == *.cfg ]] && tr '\n' ' ' <"${f}" || echo UKI)"
	done
	umount "${esp}" 2>/dev/null || true
}

# Prints the end of the VM's serial console, for a boot that did not come back.
print_console() {
	echo "Last 200 lines of the serial console:" >&2
	tail -n 200 "${work}/serial.log" | tr -d '\r' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' >&2 || true
}

derive "${START_IMAGE}" ostree
derive "${image}" composefs

luks_uuid=$(< /proc/sys/kernel/random/uuid)
boot_uuid=$(< /proc/sys/kernel/random/uuid)
root_uuid=$(< /proc/sys/kernel/random/uuid)
qemu-img create -q -f qcow2 "${work}/start.qcow2" 20G
setup=$(printf '%s\nmake_start_disk %q %q %q %q\n' "$(declare -f make_start_disk)" \
	"${test_repo}:ostree" "${luks_uuid}" "${boot_uuid}" "${root_uuid}" | base64 -w0)
"${BCVK}" ephemeral run-ssh --memory 4G --bind-storage-ro \
	--mount-disk-file "${work}/start.qcow2:target:qcow2" "${test_repo}:ostree" -- \
	"echo ${setup} | base64 -d | sudo bash"

# bcvk sets up the domain (UEFI, a swtpm TPM 2.0, SSH through SMBIOS
# credentials, the host's storage at HOST_STORAGE) by installing the start
# image; its disk is then replaced with the one laid out above.
created=1
"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" run --name "${VM_NAME}" --bind-storage-ro \
	--filesystem btrfs --disk-size 20G --memory 4G --cpus 4 --platform-console-log "${work}/serial.log" \
	--detach --ssh-wait "${test_repo}:ostree"
"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" stop --force "${VM_NAME}"
disk=$(virsh -c "${BCVK_CONNECTION}" domblklist "${VM_NAME}" --details | awk '$2 == "disk" { print $4; exit }')
if [[ "${disk}" != *.qcow2 ]]; then
	echo "error: unexpected disk '${disk}' in ${VM_NAME}" >&2
	exit 1
fi
cp "${work}/start.qcow2" "${disk}"
"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" start "${VM_NAME}"
wait_for_boot '' || { print_console; exit 1; }

# Enroll the TPM without PCR binding, since the boot chain is replaced
# below; then drop the key file so only the TPM unlocks root.
key_karg="rd.luks.key=${luks_uuid}=/luks.key:UUID=${boot_uuid}"
vm "set -eu
test -d /sysroot/ostree/deploy
systemd-cryptenroll --unlock-key-file=/boot/luks.key --tpm2-device=auto --tpm2-pcrs= \
	--wipe-slot=password /dev/disk/by-uuid/${luks_uuid}
mount -o remount,rw /boot
rm /boot/luks.key
rpm-ostree kargs --delete='${key_karg}'"
reboot_and_wait || { print_console; exit 1; }
# shellcheck disable=SC2016 # expanded by the VM's shell
vm 'set -eu
if grep -q rd.luks.key /proc/cmdline; then
	echo "error: the ostree host still boots with the key file" >&2
	exit 1
fi
test "$(findmnt -no FSTYPE /sysroot)" = btrfs
findmnt -no OPTIONS /sysroot | grep -q subvol=/root
source=$(findmnt -no SOURCE /sysroot)
test "$(lsblk -no TYPE "${source%%\[*}")" = crypt'
expect_root_kargs "the ostree host's /proc/cmdline" "$(vm 'cat /proc/cmdline')"

# The physical paths of the markers, in the ostree stateroot.
old_markers=$(vm "set -eu
echo old-ostree > /etc/${OLD_MARKER}
echo old-ostree > /var/${OLD_MARKER}
mkdir -p ${OLD_HOME}
echo old-ostree > ${OLD_HOME}/${OLD_MARKER}
sync
find /sysroot/ostree/deploy -name ${OLD_MARKER} | sort")
if (($(wc -l <<<"${old_markers}") != 3)); then
	printf 'error: expected 3 markers under /sysroot/ostree/deploy, found:\n%s\n' "${old_markers}" >&2
	exit 1
fi

vm "set -eu
export STORAGE_OPTS=additionalimagestore=${HOST_STORAGE}
podman run --rm --privileged --pid=host --net=none --env=STORAGE_OPTS \
	-v ${HOST_STORAGE}:${HOST_STORAGE} -v /var/lib/containers:/var/lib/containers \
	-v /var/tmp:/var/tmp -v /dev:/dev -v /:/target --security-opt label=type:unconfined_t \
	${test_repo}:composefs \
	bootc install to-existing-root --composefs-backend --acknowledge-destructive --skip-fetch-check"

# The entries that carry composefs= are the ones to-existing-root wrote; the
# old ostree ones may still be beside them.
boot_entries=$(vm "$(declare -f list_boot_entries); list_boot_entries")
printf 'Boot entries after to-existing-root (path, options):\n%s\n' "${boot_entries}"
composefs_options=$(awk -F '\t' '$2 ~ /(^| )composefs=/ { print $2 }' <<<"${boot_entries}")
if [[ -n "${composefs_options}" ]]; then
	expect_root_kargs "the boot entry to-existing-root wrote" "${composefs_options}"
else
	echo "warning: no boot entry with composefs= found; the reboot decides" >&2
fi

if ! reboot_and_wait; then
	print_console
	echo "error: the new system did not unlock root and boot" >&2
	exit 1
fi
# shellcheck disable=SC2016 # expanded by the VM's shell
vm 'set -eu
systemctl is-system-running --wait >/dev/null || true
systemctl is-active multi-user.target
bootc status --format=json | jq -e ".status.booted.composefs != null and .status.booted.ostree == null" >/dev/null'
booted=$(vm "cat ${MARKER}")
if [[ "${booted}" != composefs ]]; then
	echo "error: booted marker is '${booted}', expected 'composefs'" >&2
	exit 1
fi
expect_root_kargs "the new system's /proc/cmdline" "$(vm 'cat /proc/cmdline')"

# shellcheck disable=SC2016 # expanded by the VM's shell
vm "set -eu
for marker in ${old_markers//$'\n'/ }; do
	test \"\$(cat \"\${marker}\")\" = old-ostree
done
leaked=\$(find /etc /var -xdev -name ${OLD_MARKER} 2>/dev/null)
if [ -n \"\${leaked}\" ]; then
	echo \"error: old markers in the running system: \${leaked}\" >&2
	exit 1
fi"

echo "to-existing-root test passed"
