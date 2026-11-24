#!/usr/bin/bash
# Add atomic-linux's host pieces to Utah (Containerfile.utah): k3s and its
# configuration, the firewalld zones, the install configuration, key-only
# sshd settings and the composefs-native setup with our forge bootc. Keep
# Utah's desktop and updater, and extend its Flatpak preinstall list.

set -euo pipefail

# The parts of custom/system this variant takes. Cockpit, restic,
# runner.slice, registries.conf, the presets and the update drop-in stay with
# the default image.
readonly SYSTEM_PATHS=(
	etc/firewalld
	etc/rancher
	etc/ssh/sshd_config.d
	usr/lib/bootc/install
	usr/lib/k3s-host
	usr/lib/systemd/system/k3s-preflight.service
	usr/lib/systemd/system/k3s.service
	usr/libexec/k3s-preflight
	usr/libexec/k3s-validate
)

echo "::group:: atomic-linux files for Utah"
for path in "${SYSTEM_PATHS[@]}"; do
	rsync -rvK --relative "/ctx/custom/system/./${path}" /
done
echo "::endgroup::"

# Use Utah's existing preinstall service and Flathub remote.
install -Dm0644 /ctx/build/utah.preinstall /usr/share/flatpak/preinstall.d/atomic-linux-utah.preinstall

# The default forge carry replaces Utah's bootc (1.17.4 when this was
# written) for the fork's to-existing-root fixes. Its fc44 RPM installs on
# Hummingbird's package base as it is.
/ctx/build/15-bootc.sh

# Also enables firewalld with our locked-down FedoraWorkstation zone as the
# default, replacing Utah's lax zone.
/ctx/build/20-k3s.sh
