#!/usr/bin/bash
# Run inside a transient-/etc VM by transient-etc-vm-test.sh: exercise
# common services so their writes to /etc show up in the report. A failed
# step is a finding, not a test failure: it prints a Markdown list of steps
# and their results on stdout and the commands' output on stderr.

set -uo pipefail

readonly CONNECTION=atomic-linux-transient-etc-test
readonly PODMAN_IMAGE=quay.io/libpod/alpine:latest
readonly STEP_TIMEOUT_SECS=600

step() {
	local desc=$1
	shift
	if "$@" >&2; then
		printf -- '- ok: %s\n' "${desc}"
	else
		printf -- '- **failed** (exit %s): %s\n' "$?" "${desc}"
	fi
}

wait_for() {
	local deadline=$((SECONDS + STEP_TIMEOUT_SECS))
	until "$@"; do
		((SECONDS < deadline)) || return 1
		sleep 5
	done
}

# One unit per call: is-active succeeds if any of several units is active.
step 'graphical.target reached' wait_for systemctl is-active --quiet graphical.target
step 'gdm active' wait_for systemctl is-active --quiet gdm.service
step 'NetworkManager: add a connection' timeout "${STEP_TIMEOUT_SECS}" nmcli connection add type dummy ifname atltest0 con-name "${CONNECTION}" \
	ipv4.method manual ipv4.addresses 192.0.2.1/24
step 'NetworkManager: remove it' timeout "${STEP_TIMEOUT_SECS}" nmcli connection delete "${CONNECTION}"
step 'firewalld: runtime port change' timeout "${STEP_TIMEOUT_SECS}" firewall-cmd --add-port=8080/tcp
step 'firewalld: revert it' timeout "${STEP_TIMEOUT_SECS}" firewall-cmd --remove-port=8080/tcp
step "podman run ${PODMAN_IMAGE}" timeout "${STEP_TIMEOUT_SECS}" podman run --rm "${PODMAN_IMAGE}" true
step 'timedatectl set-timezone' timeout "${STEP_TIMEOUT_SECS}" timedatectl set-timezone America/New_York
step 'hostnamectl set-hostname' timeout "${STEP_TIMEOUT_SECS}" hostnamectl set-hostname atomic-linux-transient-etc
step 'k3s: enable, through k3s-preflight' timeout "${STEP_TIMEOUT_SECS}" systemctl enable --now k3s.service
step 'k3s: k3s-validate passes' timeout "${STEP_TIMEOUT_SECS}" /usr/libexec/k3s-validate
step 'system running, no failed units' timeout "${STEP_TIMEOUT_SECS}" systemctl is-system-running --wait
systemctl --failed --no-legend --plain | awk '{ print "  - failed unit: " $1 }'
