#!/usr/bin/bash
# Installed disposable VM test from PR #17, not bcvk ephemeral (virtiofs
# skips ostree-prepare-root). Findings are non-gating; failed collection,
# boot, or transient-mount/reset assertions fail acceptance.
# Usage: transient-etc-vm-test.sh IMAGE [REPORT]
# Environment: BCVK, BCVK_CONNECTION; KEEP_FAILED_VM=1 retains a failed VM.

set -euo pipefail

image="${1:?usage: $0 IMAGE [REPORT]}"
report="${2:-output/transient-etc-report.md}"
tests_dir=$(dirname "$0")
# shellcheck source=tests/libvirt-vm.sh
source "${tests_dir}/libvirt-vm.sh"

# A wedged SSH client/guest or libvirt operation must not hang acceptance or
# its EXIT trap. One host-side deadline mechanism, including forced teardown
# of clients which ignore TERM; no guest security policy is changed.
VM_CALL_TIMEOUT="${VM_CALL_TIMEOUT:-120}"
INSTALL_TIMEOUT_SECS="${INSTALL_TIMEOUT_SECS:-1800}"
EXERCISE_TIMEOUT_SECS="${EXERCISE_TIMEOUT_SECS:-900}"
DIAGNOSTIC_TIMEOUT_SECS="${DIAGNOSTIC_TIMEOUT_SECS:-30}"
CLEANUP_TIMEOUT_SECS="${CLEANUP_TIMEOUT_SECS:-60}"
for setting in VM_CALL_TIMEOUT INSTALL_TIMEOUT_SECS EXERCISE_TIMEOUT_SECS DIAGNOSTIC_TIMEOUT_SECS CLEANUP_TIMEOUT_SECS BOOT_WAIT_SECS; do
	if [[ ! "${!setting}" =~ ^[1-9][0-9]*$ ]]; then
		printf 'error: %s must be a positive integer in seconds\n' "${setting}" >&2
		exit 2
	fi
done

readonly MARKER=/etc/atomic-linux-transient-etc-test
readonly PROBE=/etc/atomic-linux-transient-etc-audit-probe
run_id=$(< /proc/sys/kernel/random/uuid)
VM_NAME="atomic-linux-transient-etc-${run_id:0:8}"
created=0
mkdir -p "$(dirname "${report}")"
diagnostics="${report%.md}-diagnostics"
mkdir -p "${diagnostics}"
printf '# Transient /etc acceptance\n\nImage: %s\n\nInitial state: incomplete. See final acceptance status below.\n' "${image}" >"${report}"

cleanup() {
	status=$?
	trap - EXIT
	if ((created)); then
		VM_CALL_TIMEOUT="${DIAGNOSTIC_TIMEOUT_SECS}"
		# Best effort, before deleting the VM. No /etc contents are archived.
		vm 'journalctl -b --no-pager' >"${diagnostics}/journal.txt" 2>&1 || true
		vm 'journalctl -b -1 --no-pager' >"${diagnostics}/previous-journal.txt" 2>&1 || true
		vm 'cat /var/log/audit/audit.log' >"${diagnostics}/audit.log" 2>&1 || true
		vm 'auditctl -s; auditctl -l; findmnt /etc; systemctl --failed --no-pager; bootc status' >"${diagnostics}/state.txt" 2>&1 || true
		if ((status != 0 && ${KEEP_FAILED_VM:-0} == 1)); then
			printf 'Retaining failed VM %s\n' "${VM_NAME}" >&2
		else
			if timeout --kill-after=2s "${CLEANUP_TIMEOUT_SECS}s" "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" rm --force "${VM_NAME}" >"${diagnostics}/cleanup.log" 2>&1; then
				printf '\nVM cleanup passed.\n' >>"${report}"
			else
				cleanup_status=$?
				printf '\n**VM cleanup failed (exit %s); VM may remain.**\n' "${cleanup_status}" >>"${report}"
				if ((status == 0)); then status=${cleanup_status}; fi
			fi
		fi
	fi
	if ((status == 0)); then
		printf '\n**Acceptance passed; service findings and audit coverage gaps are above.**\n' >>"${report}"
	else
		printf '\n**Acceptance FAILED.**\n' >>"${report}"
	fi
	printf '\nAcceptance exit status: %s (zero requires mount/reset assertions and report collection).\n' "${status}" >>"${report}"
	cat "${report}"
	exit "${status}"
}
trap cleanup EXIT

expect_transient_etc() {
	# shellcheck disable=SC2016 # expanded by the VM's shell
	vm 'set -eu
test "$(findmnt -no FSTYPE /etc)" = overlay
upper=$(findmnt -no OPTIONS /etc | tr , "\n" | sed -n "s/^upperdir=//p")
test -n "${upper}"
test "$(findmnt -no FSTYPE --target "${upper}")" = tmpfs
echo "/etc is an overlay with its upperdir ${upper} on tmpfs"'
}

vm_script() {
	local interpreter=$1 script
	# Callers use this function in conditionals, where errexit is disabled.
	script=$(base64 -w0 "$2") || return "$?"
	vm "echo ${script} | base64 -d > /var/tmp/atomic-linux-test-script && ${interpreter} /var/tmp/atomic-linux-test-script"
}

created=1
timeout --kill-after=2s "${INSTALL_TIMEOUT_SECS}s" "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" run --name "${VM_NAME}" --target-transport containers-storage \
	--filesystem btrfs --disk-size 40G --memory 8G --cpus 4 --detach --ssh-wait "${image}" \
	>"${diagnostics}/install.log" 2>&1

expect_transient_etc >>"${report}"
vm "echo before-reboot > ${MARKER}"
reboot_and_wait
expect_transient_etc >>"${report}"
# Assert absence directly: a lost SSH connection must not look like absence.
vm "test ! -e ${MARKER}"
printf '\nMount and reboot-reset assertions passed.\n\n## Exercised\n\n' >>"${report}"
VM_CALL_TIMEOUT="${EXERCISE_TIMEOUT_SECS}" vm_script bash "${tests_dir}/transient-etc-exercise.sh" >>"${report}" 2>"${diagnostics}/exercise.log" ||
	printf '\n**Exercise script failed (exit %s); scope is incomplete.**\n' "$?" >>"${report}"

# Create then delete: the collector must observe a path absent from upperdir.
vm "set -eu; echo probe > ${PROBE}; rm ${PROBE}; sleep 3"
printf '\n## Observations\n\n' >>"${report}"
if vm_script 'python3 -I' "${tests_dir}/transient-etc-report.py" >>"${report}" 2>"${diagnostics}/collector.log"; then
	printf '\nReport collection passed.\n' >>"${report}"
else
	status=$?
	printf '\n**Report collection failed (exit %s); acceptance FAILED.**\n' "${status}" >>"${report}"
	exit "${status}"
fi
