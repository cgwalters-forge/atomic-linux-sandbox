#!/usr/bin/bash
# Optionally replace Fedora's bootc and make the image composefs-native.
#
# BOOTC_SOURCE selects where bootc comes from:
#   fedora           the base image's bootc, unchanged (the default)
#   updates-testing  the newest Fedora build, from updates-testing
#   copr             bootc's upstream main branch, from the rhcontainerbot/bootc
#                    COPR (Packit builds of every merge)
#
# STORAGE_BACKEND selects what `bootc install` sets up:
#   ostree     the default
#   composefs  bootc's composefs backend (bootc-composefs(7)). The image ships
#              /usr/lib/composefs/setup-root-conf.toml and no ostree
#              prepare-root.conf, which is how bootc install recognizes a
#              composefs-native image, and its initramfs gains bootc's 51bootc
#              dracut module, which mounts the composefs root.
#
# ETC_MODE selects how /etc is mounted at boot:
#   persistent  the default
#   transient   ostree's etc.transient (ostree-prepare-root(1)): /etc is an
#               overlay of the image's /etc with its upper on a tmpfs in /run,
#               so nothing written to /etc survives a reboot. A test variant
#               (README, "transient /etc"), ostree backend only: it also gets
#               custom/transient-etc, which turns on audit from boot and
#               watches writes to /etc, for tests/transient-etc-vm-test.sh to
#               attribute them.

set -euo pipefail
# Also inside $(regenerate_initramfs), so a failed dracut stops the build.
shopt -s inherit_errexit

readonly BOOTC_COPR="rhcontainerbot/bootc"
readonly DRACUT_CONF=/usr/lib/dracut/dracut.conf.d/50-atomic-linux-bootc.conf
readonly SETUP_ROOT_CONF=/usr/lib/composefs/setup-root-conf.toml
readonly PREPARE_ROOT_CONF=/usr/lib/ostree/prepare-root.conf

BOOTC_SOURCE="${BOOTC_SOURCE:-fedora}"
STORAGE_BACKEND="${STORAGE_BACKEND:-ostree}"
ETC_MODE="${ETC_MODE:-persistent}"

case "${ETC_MODE}" in
persistent) ;;
transient)
	# The composefs backend removes prepare-root.conf and mounts /etc
	# itself, so the setting would silently do nothing there.
	if [[ "${STORAGE_BACKEND}" != ostree ]]; then
		echo "error: ETC_MODE=transient needs STORAGE_BACKEND=ostree, not '${STORAGE_BACKEND}'" >&2
		exit 1
	fi
	;;
*)
	echo "error: unknown ETC_MODE '${ETC_MODE}' (expected persistent or transient)" >&2
	exit 1
	;;
esac

# Rebuild the one kernel's initramfs from the image's /usr and print its path.
regenerate_initramfs() {
	local kernels kver
	# Exactly one kernel is expected in a bootc image.
	shopt -s nullglob
	kernels=(/usr/lib/modules/*/vmlinuz)
	shopt -u nullglob
	if ((${#kernels[@]} != 1)); then
		echo "error: expected one kernel in /usr/lib/modules, found ${#kernels[@]}" >&2
		exit 1
	fi
	kver=$(basename "$(dirname "${kernels[0]}")")
	# dracut copies /root, a symlink to var/roothome that the image's /var does
	# not carry; clean-stage.sh removes this again. The base image's
	# dracut.conf.d already sets hostonly=no.
	mkdir -p /var/roothome
	DRACUT_NO_XATTR=1 dracut --force --reproducible --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img" >&2
	echo "/usr/lib/modules/${kver}/initramfs.img"
}

echo "::group:: bootc from ${BOOTC_SOURCE}"
case "${BOOTC_SOURCE}" in
fedora) ;;
updates-testing)
	dnf5 -y upgrade --enablerepo=updates-testing bootc
	;;
copr)
	# Upgrade, not install: the COPR's git-snapshot versions sort above
	# Fedora's releases, and the base image's bootc is already installed.
	dnf5 -y copr enable "${BOOTC_COPR}"
	dnf5 -y copr disable "${BOOTC_COPR}"
	dnf5 -y upgrade --enablerepo="copr:copr.fedorainfracloud.org:${BOOTC_COPR//\//:}" bootc
	;;
*)
	echo "error: unknown BOOTC_SOURCE '${BOOTC_SOURCE}' (expected fedora, updates-testing or copr)" >&2
	exit 1
	;;
esac
rpm -q bootc
echo "::endgroup::"

case "${STORAGE_BACKEND}" in
ostree)
	# The base initramfs has ostree's prepare-root and not bootc's module,
	# so a different bootc does not require regenerating it.
	[[ "${ETC_MODE}" == transient ]] || exit 0

	echo "::group:: transient /etc"
	# ostree also reads /etc/ostree/prepare-root.conf, which would override
	# this; the base has none, and appending keeps its composefs and sysroot
	# keys.
	if [[ ! -f "${PREPARE_ROOT_CONF}" || -e /etc/ostree/prepare-root.conf ]] || grep -q '^\[etc\]' "${PREPARE_ROOT_CONF}"; then
		echo "error: expected ${PREPARE_ROOT_CONF} without an [etc] section, and no /etc/ostree/prepare-root.conf" >&2
		exit 1
	fi
	printf '[etc]\ntransient = true\n' >>"${PREPARE_ROOT_CONF}"

	# The boot arguments and audit watch that the VM test's report needs.
	rsync -rvK --chmod=D0755,F0644 /ctx/custom/transient-etc/ /
	systemctl enable atomic-linux-etc-watch.service

	# ostree's dracut module copies prepare-root.conf into the initramfs,
	# where ostree-prepare-root reads it. Its check() leaves it out unless
	# asked for (the base image's build passed --add ostree).
	printf '# Mount the ostree root in the initramfs (ostree-prepare-root(1)).\nadd_dracutmodules+=" ostree "\n' >"${DRACUT_CONF}"
	initramfs=$(regenerate_initramfs)
	# Not grep -q: with pipefail, lsinitrd would die of SIGPIPE.
	if ! lsinitrd -f "${PREPARE_ROOT_CONF#/}" "${initramfs}" | grep -x 'transient = true' >/dev/null; then
		echo "error: the regenerated initramfs's prepare-root.conf lacks etc.transient" >&2
		exit 1
	fi
	echo "::endgroup::"
	exit 0
	;;
composefs) ;;
*)
	echo "error: unknown STORAGE_BACKEND '${STORAGE_BACKEND}' (expected ostree or composefs)" >&2
	exit 1
	;;
esac

# bootc 1.17.0 declared the backend stable, and older releases neither pick
# composefs from setup-root-conf.toml nor pass bootc container lint without
# ostree's prepare-root.conf.
readonly COMPOSEFS_MIN_BOOTC="1.17"
bootc_version=$(bootc --version | awk '{print $2}')
if [[ "$(printf '%s\n' "${COMPOSEFS_MIN_BOOTC}" "${bootc_version}" | sort -V | head -n1)" != "${COMPOSEFS_MIN_BOOTC}" ]]; then
	echo "error: STORAGE_BACKEND=composefs needs bootc ${COMPOSEFS_MIN_BOOTC} or newer, found ${bootc_version}; set BOOTC_SOURCE=updates-testing or copr" >&2
	exit 1
fi

echo "::group:: composefs-native image"
# An empty file is valid and means the defaults (bootc-setup-root-conf.toml(5)).
install -D -m 0644 /dev/null "${SETUP_ROOT_CONF}"
rm -f /usr/lib/ostree/prepare-root.conf /etc/ostree/prepare-root.conf

printf '# Mount the composefs root in the initramfs (bootc-root-setup.service(5)).\nadd_dracutmodules+=" bootc "\n' >"${DRACUT_CONF}"

initramfs=$(regenerate_initramfs)
# Not grep -q: with pipefail, lsinitrd would die of SIGPIPE.
if ! lsinitrd "${initramfs}" | grep 'usr/lib/bootc/initramfs-setup' >/dev/null; then
	echo "error: the regenerated initramfs lacks bootc's initramfs-setup" >&2
	exit 1
fi
echo "::endgroup::"
