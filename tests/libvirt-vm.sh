#!/usr/bin/bash
# Helpers for the disposable libvirt VM tests, sourced by them. The caller
# sets VM_NAME, and may set BCVK, BCVK_CONNECTION and BOOT_WAIT_SECS.

BCVK="${BCVK:-bcvk}"
BCVK_CONNECTION="${BCVK_CONNECTION:-qemu:///session}"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-300}"

vm() {
	"${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${VM_NAME}" "$@"
}

# Waits for a new boot ID, so a slow shutdown is not mistaken for the reboot.
reboot_and_wait() {
	local old_boot new_boot deadline=$((SECONDS + BOOT_WAIT_SECS))
	old_boot=$(vm 'cat /proc/sys/kernel/random/boot_id')
	vm 'systemctl reboot' || true
	sleep 10
	until new_boot=$(vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && [[ "${new_boot}" != "${old_boot}" ]]; do
		if ((SECONDS > deadline)); then
			echo "error: ${VM_NAME} did not come back within ${BOOT_WAIT_SECS}s" >&2
			return 1
		fi
		sleep 5
	done
}
