#!/usr/bin/bash
# Helpers for the disposable libvirt VM tests, sourced by them. The caller
# sets VM_NAME, and may set BCVK, BCVK_CONNECTION and BOOT_WAIT_SECS.

BCVK="${BCVK:-bcvk}"
BCVK_CONNECTION="${BCVK_CONNECTION:-qemu:///session}"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-300}"

vm() {
	if [[ -n "${VM_CALL_TIMEOUT:-}" ]]; then
		timeout --kill-after=2s "${VM_CALL_TIMEOUT}s" "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${VM_NAME}" "$@"
	else
		"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${VM_NAME}" "$@"
	fi
}

# Waits for a new boot ID, so a slow shutdown is not mistaken for the reboot.
reboot_and_wait() {
	local old_boot new_boot remaining deadline=$((SECONDS + BOOT_WAIT_SECS))
	old_boot=$(vm 'cat /proc/sys/kernel/random/boot_id')
	vm 'systemctl reboot' || true
	while true; do
		remaining=$((deadline - SECONDS))
		if ((remaining <= 0)); then
			echo "error: ${VM_NAME} did not come back within ${BOOT_WAIT_SECS}s" >&2
			return 1
		fi
		# Bound each poll by the remaining budget, including an unreachable SSH.
		if new_boot=$(VM_CALL_TIMEOUT="${remaining}" vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && [[ -n "${new_boot}" && "${new_boot}" != "${old_boot}" ]]; then
			return 0
		fi
		remaining=$((deadline - SECONDS))
		if ((remaining > 0)); then sleep "$((remaining < 5 ? remaining : 5))"; fi
	done
}
