#!/usr/bin/bash
# Offline, disposable image-test container, after clean-stage.sh.
set -euo pipefail

: "${VARIANT:?VARIANT must be set}"
test "$(systemctl is-enabled flatpak-add-fedora-repos.service)" = masked
test ! -e /usr/lib/systemd/system/flatpak-add-fedora-repos.service

# Do not hide build-time state by deleting it here. Discovery must work with
# the empty /var that final cleanup leaves, using the shipped drop-ins alone.
test ! -e /var/lib/flatpak/repo/config
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
APPS="${tmp}/apps" python3 - <<'PY'
import base64
import configparser
import os
from pathlib import Path

desktop = os.environ["VARIANT"] == "desktop"
root = Path("/usr/share/flatpak")
remote = root / "remotes.d/flathub.flatpakrepo"
assert remote.exists() == desktop, "Flathub payload must be desktop-only"
entries = {}
for directory in (root / "preinstall.d", Path("/etc/flatpak/preinstall.d")):
    for path in directory.glob("*.preinstall"):
        config = configparser.ConfigParser(interpolation=None)
        config.optionxform = str
        config.read(path)
        for section in config.sections():
            assert section.startswith("Flatpak Preinstall "), (path, section)
            if config.getboolean(section, "Install", fallback=True):
                assert section not in entries, (path, section)
                entries[section] = dict(config[section])
# The desktop's set is whatever its drop-in lists; the server has none.
assert bool(entries) == desktop, entries
for section, entry in entries.items():
    assert entry == {"Branch": "stable", "CollectionID": "org.flathub.Stable"}, entry
Path(os.environ["APPS"]).write_text(
    "".join(section.removeprefix("Flatpak Preinstall ") + "\n" for section in entries))
if desktop:
    config = configparser.ConfigParser(interpolation=None)
    config.read(remote)
    repo = config["Flatpak Repo"]
    assert repo["Url"] == "https://dl.flathub.org/repo/"
    assert repo["CollectionID"] == "org.flathub.Stable"
    assert len(base64.b64decode(repo["GPGKey"], validate=True)) > 1000
PY

if command -v flatpak >/dev/null; then
	remotes=$(flatpak remotes --system --columns=name,url)
	if [[ "${VARIANT}" == desktop ]]; then
		test "${remotes}" = $'flathub\thttps://dl.flathub.org/repo/'
		# Check effective libostree settings, not just the .flatpakrepo text.
		python3 - <<'PY'
import configparser
from pathlib import Path

config = configparser.ConfigParser()
config.read("/var/lib/flatpak/repo/config")
remote = config['remote "flathub"']
assert remote.getboolean("gpg-verify")
assert remote.getboolean("gpg-verify-summary")
assert remote["collection-id"] == "org.flathub.Stable"
assert Path("/var/lib/flatpak/repo/flathub.trustedkeys.gpg").stat().st_size > 1000
PY
		# Exercise the packaged parser without pulling apps. Missing cached refs
		# can fail offline; the verbose parser must still find every active ref.
		log="${tmp}/preinstall.log"
		flatpak preinstall --system --no-pull --noninteractive --verbose >"${log}" 2>&1 || true
		arch=$(flatpak --default-arch)
		while read -r app; do
			grep -F "Found preinstall ref app/${app}/${arch}/stable" "${log}"
		done <"${tmp}/apps"
		test "$(systemctl is-enabled atomic-linux-flatpak-preinstall.service)" = enabled
	else
		test -z "${remotes}"
		test ! -e /usr/lib/systemd/system/atomic-linux-flatpak-preinstall.service
	fi
elif [[ "${VARIANT}" == desktop ]]; then
	echo 'error: desktop lacks flatpak' >&2
	exit 1
fi
