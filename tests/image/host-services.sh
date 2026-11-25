#!/usr/bin/bash
# Host services from custom/*/host-services.*: restic backups stay inert until
# configured, and the host carries no Node.js (agents run in VMs instead).
set -euo pipefail

systemd-analyze verify --man=no restic-backup.service restic-backup.timer
if systemd-analyze condition --unit=restic-backup.service >/dev/null; then
	echo "error: restic-backup.service would run without /etc/restic-backup" >&2
	exit 1
fi

if rpm -q nodejs >/dev/null; then
	echo "error: nodejs is installed" >&2
	exit 1
fi
for binary in node nodejs; do
	if path=$(command -v "${binary}"); then
		echo "error: ${binary} is installed at ${path}" >&2
		exit 1
	fi
done

# The base Cockpit components must be present in both variants, but no listener
# should be enabled. This runs in a disposable image-test container, not a host.
rpm -q cockpit-ws cockpit-system cockpit-podman cockpit-storaged cockpit-networkmanager
assert_cockpit_disabled() {
	local state
	state=$(systemctl is-enabled cockpit.socket || true)
	if [[ "${state}" != disabled ]]; then
		echo "error: cockpit.socket is '${state}', expected disabled (not masked)" >&2
		exit 1
	fi
}
assert_cockpit_disabled
# Prove opt-in works, then exercise the first-boot operation with the actual
# installed vendor presets. The preset must undo prior explicit enablement.
systemctl enable cockpit.socket
[[ $(systemctl is-enabled cockpit.socket) == enabled ]]
systemctl preset-all
assert_cockpit_disabled
