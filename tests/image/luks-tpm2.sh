#!/usr/bin/bash
# `bootc install --block-setup tpm2-luks` (docs/install.md) needs the install
# configuration to permit it, the tools to format and enroll the root, and
# an initramfs that unlocks it with the TPM. Without the last the install
# succeeds but the root never unlocks.
set -euo pipefail

for tool in cryptsetup systemd-cryptenroll lsinitrd; do
	if ! command -v "${tool}" >/dev/null; then
		echo "error: ${tool} is missing" >&2
		exit 1
	fi
done

config=$(bootc install print-configuration)
if ! grep -q '"block":\[[^]]*"tpm2-luks"' <<<"${config}"; then
	echo "error: install configuration does not permit tpm2-luks: ${config}" >&2
	exit 1
fi

kernels=(/usr/lib/modules/*/initramfs.img)
if ((${#kernels[@]} != 1)) || [[ ! -f "${kernels[0]}" ]]; then
	echo "error: expected one initramfs, found: ${kernels[*]}" >&2
	exit 1
fi
initramfs=${kernels[0]}

# lsinitrd warns on stderr about the uncompressed early microcode archive.
if ! modules=$(lsinitrd -m "${initramfs}" 2>/dev/null) ||
	! files=$(lsinitrd "${initramfs}" 2>/dev/null); then
	echo "error: lsinitrd cannot read ${initramfs}" >&2
	exit 1
fi

for module in systemd-cryptsetup tpm2-tss; do
	if ! grep -qxF "${module}" <<<"${modules}"; then
		echo "error: ${initramfs} lacks the ${module} dracut module" >&2
		exit 1
	fi
done

for file in usr/bin/systemd-cryptsetup usr/lib64/cryptsetup/libcryptsetup-token-systemd-tpm2.so; do
	if ! grep -qE " ${file}( -> .*)?\$" <<<"${files}"; then
		echo "error: ${initramfs} lacks ${file}" >&2
		exit 1
	fi
done
