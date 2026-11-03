#!/usr/bin/bash
# Lifecycle check for a composefs-native build (`just build-composefs`) in a
# disposable libvirt VM: install, then upgrade, switch and rollback across
# three derived images, with an /etc and /var edit that must survive.
#
# Usage: composefs-vm-test.sh IMAGE (e.g. localhost/atomic-linux:composefs)
# Environment: BCVK, BCVK_CONNECTION, PODMAN; KEEP_FAILED_VM=1 keeps a
# failed VM for debugging.

set -euo pipefail

image="${1:?usage: $0 IMAGE}"
PODMAN="${PODMAN:-podman}"
# shellcheck source=tests/libvirt-vm.sh
source "$(dirname "$0")/libvirt-vm.sh"

readonly MARKER=/usr/share/atomic-linux-composefs-test

run_id=$(< /proc/sys/kernel/random/uuid)
VM_NAME="atomic-linux-composefs-${run_id:0:8}"
# bootc upgrade re-pulls the booted reference, so "current" is retagged to
# the next build; "other" is the bootc switch target.
test_repo="localhost/atomic-linux-composefs-test-${run_id:0:8}"
created=0
built_ids=()
builddir=$(mktemp -d)

cleanup() {
	status=$?
	rm -rf "${builddir}"
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
	local marker=$1 tag=$2
	printf 'FROM %s\nRUN echo %s > %s\n' "${image}" "${marker}" "${MARKER}" >"${builddir}/Containerfile"
	built_ids+=("$("${PODMAN}" build --quiet --tag "${test_repo}:${tag}" "${builddir}")")
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

derive one current
derive three other

# --update-from-host binds the host's containers-storage so that bootc
# upgrade and switch in the VM see the images built above. Set created
# first: a failed SSH wait can still leave a defined VM behind.
created=1
"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" run --name "${VM_NAME}" --update-from-host \
	--filesystem btrfs --disk-size 20G --memory 4G --cpus 4 --detach --ssh-wait "${test_repo}:current"

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

derive two current
vm 'bootc upgrade'
reboot_and_wait
expect_marker two
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
