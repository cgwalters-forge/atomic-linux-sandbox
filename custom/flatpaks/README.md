# Flatpak preinstall integration

> This text is LLM generated.

This directory is documentation only. Active configuration lives in the
[desktop variant](../variants/desktop/system/usr/share/flatpak/), copied by
the existing variant system drop-ins, not by the shared base. Personal app
lists belong downstream.

## Packaged interface and invocation

The Fedora 45 release RPM `flatpak-1.19.0^really1.18.4-1.fc45.x86_64`
was inspected from the [Fedora mirror](https://rpmfind.net/linux/fedora/linux/releases/45/Everything/x86_64/os/Packages/f/).
Its shipped `flatpak-preinstall(1)` documents INI groups named
`[Flatpak Preinstall APP_ID]`, with `Branch`, `IsRuntime`, `Install` and
`CollectionID` keys, under `/usr/share/flatpak/preinstall.d/` and
`/etc/flatpak/preinstall.d/`. `Install` defaults to true, `IsRuntime` to
false; the branch defaults to master, so these defaults explicitly request
stable. Every entry binds to `org.flathub.Stable`, also set on the remote.
The official remote's public key is retained; neither commit nor summary
signature verification is disabled.

That RPM ships the CLI and system helper, but no preinstall startup unit.
Its `flatpak-add-fedora-repos.service` only runs two Fedora `remote-add`
commands and writes `.fedora-initialized`; it does not invoke preinstall,
and this image masks and removes it. The manual says the OS runs
`flatpak preinstall -y` on startup, so the desktop ships and enables its own
`atomic-linux-flatpak-preinstall.service`, as Bluefin's common layer does
with `flatpak-preinstall.service`. It runs the packaged CLI as a `Type=exec`
service after `network-online.target`, so boot does not wait for downloads,
and gives up for that boot after three failed attempts. Downloads start at boot,
never at image build. Apps, runtimes and extensions take about 1.5 GB of
bandwidth and disk. Offline discovery of the remote works with its shipped
key, but a fresh offline machine cannot install the defaults until a later
boot is online, or until an administrator runs
`sudo flatpak preinstall --system --noninteractive`.

## Downstream overrides

Derived desktop images can replace
`/usr/share/flatpak/preinstall.d/default.preinstall` or add their own files,
or `systemctl disable atomic-linux-flatpak-preinstall.service` to leave
installation to the administrator.
Administrators can override individual groups in
`/etc/flatpak/preinstall.d/local.preinstall`, for example:

```ini
[Flatpak Preinstall org.gnome.Calculator]
Install=false
```

Flatpak reads `/etc` after `/usr/share`, merging keys by app group. Extra
apps should specify `Branch=stable` and `CollectionID=org.flathub.Stable`.
Removing vendor configuration is not a general-purpose uninstall operation;
use Flatpak to manage already installed apps. The packaged manual says a
user-uninstalled preinstall is remembered and is not automatically restored.
For remotes, remove the vendor `.flatpakrepo` in a derived image to omit the
default on fresh hosts; existing `/var` remote state must be managed with
`flatpak remote-modify` or `flatpak remote-delete --system`. Image changes
do not erase existing installations or user remotes on upgraded hosts.

## Verification boundaries

`just image-test` runs offline after final build cleanup. The Flatpak check
requires no preexisting system repository, calls `flatpak remotes --system`
to test discovery, checks the effective URL, collection ID, imported key and
commit/summary verification settings, excludes Fedora remotes, validates the
active entries, exercises the packaged preinstall parser without pulling,
checking that it finds every listed app, and checks the service is enabled.
It checks that the server has neither Flathub, active preinstall entries nor
the service. It is not an app-installation test.

In a disposable networked desktop VM, wait for the service to finish
(`journalctl -u atomic-linux-flatpak-preinstall -f`), then check
`flatpak list --system --app --columns=application,branch,origin` lists the
stable apps from flathub. Inspection of the release RPM is not verification
of the final image's package version.
