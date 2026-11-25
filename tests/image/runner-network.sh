#!/usr/bin/bash
# runner-network ships inert and its ruleset from the example config
# validates; a malformed config is refused.
set -euo pipefail

script=/usr/libexec/atomic-linux/runner-network
example=/usr/share/atomic-linux/runner-network.conf.example

if [[ -e /etc/atomic-linux/runner-network.conf ]]; then
	echo "error: the image must not ship a runner-network config" >&2
	exit 1
fi

bash "${script}" ruleset "${example}" | nft -c -f -

bad=$(mktemp)
trap 'rm -f "${bad}"' EXIT
for line in 'allow 198.51.100.0/24; flush ruleset' 'allow 192.168.1.5/16'; do
	printf 'dns 192.0.2.53\n%s\n' "${line}" >"${bad}"
	if err=$(bash "${script}" ruleset "${bad}" 2>&1 >/dev/null) || [[ "${err}" != *":2: "* ]]; then
		echo "error: '${line}' was not refused: ${err}" >&2
		exit 1
	fi
done
