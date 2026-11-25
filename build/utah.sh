#!/usr/bin/bash
# Add atomic-linux's host pieces to Utah (Containerfile.utah): k3s and its
# configuration, the firewalld zones, the install configuration, key-only
# sshd settings and the composefs-native setup. Keep Utah's desktop,
# updater and bootc, and extend its Flatpak preinstall list.

set -euo pipefail

# The parts of custom/system this variant takes. Cockpit, restic,
# runner.slice, runner-network, registries.conf, the presets and the update
# drop-in stay with the default image. Only import firewall files Utah uses.
readonly SYSTEM_PATHS=(
	etc/firewalld/services/tailscale.xml
	etc/firewalld/zones/FedoraWorkstation.xml
	etc/firewalld/zones/k3s.xml
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

# fedora keeps the base image's bootc, here Utah's (1.17.4 when this was
# written), which lacks the fork's to-existing-root fixes.
BOOTC_SOURCE=fedora /ctx/build/15-bootc.sh

# Also enables firewalld with our locked-down FedoraWorkstation zone as the
# default, replacing Utah's lax zone.
/ctx/build/20-k3s.sh
