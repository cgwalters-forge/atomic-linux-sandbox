#!/usr/bin/bash
# Install a transient-/etc build (`just build-transient-etc`) in a disposable
# libvirt VM, check that /etc is a tmpfs-backed overlay that a reboot resets,
# then exercise common services (transient-etc-exercise.sh) and write a
# Markdown report of what they wrote to /etc and who wrote it
# (transient-etc-report.py). It fails only if the VM does not boot or /etc is
# not transient; the report's findings are output. `bcvk ephemeral` cannot
# test this: it boots over virtiofs without ostree-prepare-root.
#
# Usage: transient-etc-vm-test.sh IMAGE [REPORT]
#   (e.g. localhost/atomic-linux:transient-etc output/transient-etc-report.md)
# Environment: BCVK, BCVK_CONNECTION; KEEP_FAILED_VM=1 keeps a failed VM for
# debugging.

set -euo pipefail

image="${1:?usage: $0 IMAGE [REPORT]}"
report="${2:-output/transient-etc-report.md}"
tests_dir=$(dirname "$0")
# shellcheck source=tests/libvirt-vm.sh
source "${tests_dir}/libvirt-vm.sh"

readonly MARKER=/etc/atomic-linux-transient-etc-test

run_id=$(< /proc/sys/kernel/random/uuid)
VM_NAME="atomic-linux-transient-etc-${run_id:0:8}"
created=0

cleanup() {
	status=$?
	if ((status != 0 && ${KEEP_FAILED_VM:-0} == 1)); then
		printf 'Retaining failed VM %s\n' "${VM_NAME}" >&2
		exit "${status}"
	fi
	if ((created)); then
		"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" rm --force "${VM_NAME}" || status=1
	fi
	exit "${status}"
}
trap cleanup EXIT

# The upperdir is read from the mount, not assumed: ostree picks its name.
expect_transient_etc() {
	# shellcheck disable=SC2016 # expanded by the VM's shell
	vm 'set -eu
test "$(findmnt -no FSTYPE /etc)" = overlay
upper=$(findmnt -no OPTIONS /etc | tr , "\n" | sed -n "s/^upperdir=//p")
test -n "${upper}"
test "$(findmnt -no FSTYPE --target "${upper}")" = tmpfs
echo "/etc is an overlay with its upperdir ${upper} on tmpfs"'
}

# Run a local script in the VM as root.
vm_script() {
	local interpreter=$1 script
	script=$(base64 -w0 "$2")
	vm "echo ${script} | base64 -d > /var/tmp/atomic-linux-test-script && ${interpreter} /var/tmp/atomic-linux-test-script"
}

# Set created first: a failed SSH wait can still leave a defined VM behind.
# k3s needs the memory and disk of k3s-vm-create.
created=1
"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" run --name "${VM_NAME}" --target-transport containers-storage \
	--filesystem btrfs --disk-size 40G --memory 8G --cpus 4 --detach --ssh-wait "${image}"

expect_transient_etc
vm "echo before-reboot > ${MARKER}"
reboot_and_wait
expect_transient_etc
if vm "test -e ${MARKER}"; then
	echo "error: ${MARKER} survived a reboot; /etc is not transient" >&2
	exit 1
fi
echo "${MARKER} is gone after a reboot"

# From here on a failure, even a lost SSH connection, is a finding in the
# report, not a test failure.
mkdir -p "$(dirname "${report}")"
{
	printf '# Runtime writes to a transient /etc\n\nImage %s, one boot after install.\n\n## Exercised\n\n' "${image}"
	vm_script bash "${tests_dir}/transient-etc-exercise.sh" || printf '\n**The exercise script failed (exit %s).**\n' "$?"
	printf '\n## Writes\n\n'
	vm_script 'python3 -I' "${tests_dir}/transient-etc-report.py" || printf '\n**The report script failed (exit %s).**\n' "$?"
} >"${report}"
cat "${report}"
echo "transient /etc test passed; report in ${report}"
