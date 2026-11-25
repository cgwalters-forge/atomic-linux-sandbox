#!/usr/bin/bash
# Lifecycle check for a composefs-native build (`just build`) in a
# disposable libvirt VM: install, then stage, switch and roll back across
# three derived images, with an /etc and /var edit that must survive. After
# the install it records which bootloader started the system, the Secure
# Boot state and the ESP's headroom (libvirt-vm.sh, check_boot).
#
# Usage: composefs-vm-test.sh IMAGE (e.g. localhost/atomic-linux:composefs)
# Environment: BCVK, BCVK_CONNECTION, PODMAN, EXPECT_BOOTLOADER (grub);
# KEEP_FAILED_VM=1 keeps a failed VM for debugging.
# COMPOSEFS_TEST_UPDATE_SERVICE=0 uses a manual upgrade on images that
# intentionally mask the bootc update timer and service.

set -euo pipefail

image="${1:?usage: $0 IMAGE}"
# shellcheck source=tests/libvirt-vm.sh
source "$(dirname "$0")/libvirt-vm.sh"

readonly MARKER=/usr/share/atomic-linux-composefs-test
readonly TEST_UPDATE_SERVICE="${COMPOSEFS_TEST_UPDATE_SERVICE:-1}"

run_id=$(< /proc/sys/kernel/random/uuid)
VM_NAME="atomic-linux-composefs-${run_id:0:8}"
# bootc upgrade re-pulls the booted reference, so "current" is retagged to
# the next build; "other" is the bootc switch target.
test_repo="localhost/atomic-linux-composefs-test-${run_id:0:8}"
created=0
built_ids=()

cleanup() {
	status=$?
	if ((status != 0 && ${KEEP_FAILED_VM:-0} == 1)); then
		printf 'Retaining failed VM %s and its images %s:*\n' "${VM_NAME}" "${test_repo}" >&2
		exit "${status}"
	fi
	if ((created)); then
		"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" rm --force "${VM_NAME}" || status=1
	fi
	# By ID: retagging "current" leaves earlier builds untagged.
	if ((${#built_ids[@]})); then
		"${PODMAN}" rmi --force --ignore "${built_ids[@]}" >/dev/null || status=1
	fi
	exit "${status}"
}
trap cleanup EXIT

# Build IMAGE plus a marker file naming the build, tagged as $2.
derive() {
	local id
	id=$(derive_image "${image}" "$1" "${MARKER}" "${test_repo}:$2")
	built_ids+=("${id}")
}

expect_marker() {
	local want=$1 got
	got=$(vm "cat ${MARKER}")
	if [[ "${got}" != "${want}" ]]; then
		echo "error: booted marker is '${got}', expected '${want}'" >&2
		return 1
	fi
	echo "booted ${want}"
}

stage_with_update_service() {
	local digest=$1 boot_id booted_verity
	boot_id=$(vm 'cat /proc/sys/kernel/random/boot_id')
	booted_verity=$(vm 'bootc status --format=json | jq -er .status.booted.composefs.verity')

	# bcvk writes the host storage setting through tmpfiles, after systemd has
	# read system.conf.d. Reload so the real oneshot can see the retagged image.
	VM_CALL_TIMEOUT="${BOOT_WAIT_SECS}" vm 'set -euo pipefail
systemctl daemon-reload
systemctl show-environment | grep -Fx STORAGE_OPTS=additionalimagestore=/run/host-container-storage
systemctl start bootc-fetch-apply-updates.service'

	# A condition skip can return success, so check the staged manifest too.
	if ! vm "bootc status --format=json | jq -e --arg ref '${test_repo}:current' --arg digest '${digest}' --arg verity '${booted_verity}' '
    .status.booted.composefs.verity == \$verity and
    .status.booted.image.imageDigest != \$digest and
    .status.staged.image.image.image == \$ref and
    .status.staged.image.imageDigest == \$digest
    ' >/dev/null"; then
		echo "error: expected ${test_repo}:current (${digest}) staged with deployment ${booted_verity} still booted" >&2
		vm 'bootc status' >&2 || true
		return 1
	fi
	test "$(vm 'cat /proc/sys/kernel/random/boot_id')" = "${boot_id}"
	expect_marker one
}

derive one current
derive three other

# Set created first: a failed SSH wait can still leave a defined VM behind.
created=1
vm_install --disk-size 20G --memory 4G --cpus 4 "${test_repo}:current"

# shellcheck disable=SC2016 # expanded by the VM's shell
vm 'set -eu
bootc status --format=json | jq -e ".status.booted.composefs != null and .status.booted.ostree == null" >/dev/null
test "$(findmnt -no SOURCE /)" = "composefs:$(bootc status --format=json | jq -r .status.booted.composefs.verity)"
test "$(getenforce)" = Enforcing
systemctl start k3s-preflight.service
systemctl is-active k3s-preflight.service
echo local-etc > /etc/atomic-linux-composefs-test
echo local-var > /var/atomic-linux-composefs-test'
expect_marker one
check_boot

if [[ "${TEST_UPDATE_SERVICE}" != 0 ]]; then
	# Keep the production schedule from racing the explicit start below.
	vm 'set -eu
test ! -e /run/ostree-booted
systemctl is-active bootc-fetch-apply-updates.timer
systemctl stop bootc-fetch-apply-updates.timer'
fi
derive two current
if [[ "${TEST_UPDATE_SERVICE}" != 0 ]]; then
	staged_digest=$("${PODMAN}" image inspect --format '{{.Digest}}' "${test_repo}:current")
	stage_with_update_service "${staged_digest}"
else
	vm 'bootc upgrade'
fi

reboot_and_wait
expect_marker two
if [[ "${TEST_UPDATE_SERVICE}" != 0 ]]; then
	vm "bootc status --format=json | jq -e --arg digest '${staged_digest}' '.status.booted.image.imageDigest == \$digest' >/dev/null"
fi
# shellcheck disable=SC2016 # expanded by the VM's shell
vm 'set -eu
test "$(cat /etc/atomic-linux-composefs-test)" = local-etc
test "$(cat /var/atomic-linux-composefs-test)" = local-var
test "$(getenforce)" = Enforcing'

vm "bootc switch --transport containers-storage ${test_repo}:other"
reboot_and_wait
expect_marker three

vm 'bootc rollback'
reboot_and_wait
expect_marker two
vm "bootc status --format=json | jq -e '.status.rollback.image.image.image == \"${test_repo}:other\"' >/dev/null"

echo "composefs lifecycle test passed"
