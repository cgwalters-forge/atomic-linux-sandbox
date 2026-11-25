#!/usr/bin/bash
# The virtualization host stack: only libvirt's QEMU and network drivers,
# virtqemud answers `virsh capabilities`, VM guest agents and the CI runner
# hook stay disabled, and runner account setup allocates non-overlapping IDs.
set -euo pipefail

mapfile -t drivers < <(rpm -qa --qf '%{NAME}\n' 'libvirt-daemon-driver-*' | sort)
if [[ "${drivers[*]}" != 'libvirt-daemon-driver-network libvirt-daemon-driver-qemu' ]]; then
	echo "error: unexpected libvirt drivers: ${drivers[*]}" >&2
	exit 1
fi
for package in cockpit-machines libvirt-daemon-config-network; do
	if rpm -q "${package}" >/dev/null; then
		echo "error: unexpected package ${package}" >&2
		exit 1
	fi
done

agents=(qemu-guest-agent.service vmtoolsd.service vgauthd.service hypervfcopyd.service vboxservice.service)
for unit in "${agents[@]}" ci-runner.service; do
	# The base image need not ship every agent.
	if [[ "${unit}" != ci-runner.service && ! -e "/usr/lib/systemd/system/${unit}" ]]; then
		continue
	fi
	state=$(systemctl is-enabled "${unit}" || true)
	if [[ "${state}" != disabled ]]; then
		echo "error: ${unit} is '${state}', expected disabled" >&2
		exit 1
	fi
done

# Exercise preset precedence even when the image ships none of the agents.
# Only the unit fixtures are enabled; no real guest agent is installed or run.
root=$(mktemp -d)
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/usr/lib/systemd/system" "${root}/usr/lib/systemd/system-preset"
cp -a /usr/lib/systemd/system-preset/. "${root}/usr/lib/systemd/system-preset/"
if [[ -d /etc/systemd/system-preset ]]; then
	mkdir -p "${root}/etc/systemd/system-preset"
	cp -a /etc/systemd/system-preset/. "${root}/etc/systemd/system-preset/"
fi
for unit in "${agents[@]}"; do
	printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"${root}/usr/lib/systemd/system/${unit}"
done
systemctl --root="${root}" enable "${agents[@]}"
systemctl --root="${root}" preset-all
for unit in "${agents[@]}"; do
	state=$(systemctl --root="${root}" is-enabled "${unit}" || true)
	if [[ "${state}" != disabled ]]; then
		echo "error: preset-all leaves ${unit} '${state}', expected disabled" >&2
		exit 1
	fi
done
rm -rf "${root}"

# No systemd here, so start virtqemud by hand; it listens on its own socket.
virtqemud --timeout 60 &
trap 'kill %1 2>/dev/null || true' EXIT
for _ in {1..30}; do
	[[ -S /run/libvirt/virtqemud-sock ]] && break
	sleep 1
done
virsh -c qemu:///system capabilities | python3 -I -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
if root.find("./guest/arch[@name=\"x86_64\"]") is None:
    sys.exit("error: capabilities list no x86_64 guest")
'

bash /usr/libexec/ci-runner-account &
first=$!
useradd --no-create-home subids-test-user
wait "${first}"
bash /usr/libexec/ci-runner-account
for file in /etc/subuid /etc/subgid; do
	awk -F: '
		$1 == "ci-runner" { runner++; start = $2; end = $2 + $3 }
		$1 == "subids-test-user" { other++; other_start = $2; other_end = $2 + $3 }
		END { exit !(runner == 1 && other == 1 && (end <= other_start || other_end <= start)) }
	' "${file}" || { echo "error: missing, duplicate or overlapping ranges in ${file}" >&2; exit 1; }
done
