# Updates

> This text is LLM generated.

The image fetches and stages updates on its own but never reboots for them.
An unattended reboot would kill whatever the host is running, such as CI
jobs or an open session, at a time nobody chose, so applying an update is
left to the person or tooling that owns the host.

This image ships composefs only. rpm-ostree and GNOME Software's OS updates
do not work on composefs; use bootc for OS updates.

## What runs

The Fedora base ships two update timers and enables neither.
`rpm-ostreed-automatic.timer` stays disabled, so rpm-ostree's
`AutomaticUpdatePolicy` has no effect. This image enables
`bootc-fetch-apply-updates.timer` (first run an hour after boot, then
every 8 hours, with up to 2 hours of random delay) and replaces the
service's `bootc upgrade --apply` with `bootc upgrade --quiet` in
`/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf`.
Each run pulls the newest image for the tracked reference and, if it
changed, stages it as the deployment for the next boot.

Image drop-ins for the timer and service allow either the stock ostree boot
marker or one of the two composefs kernel arguments (`composefs` and
`composefs.digest`) that `bootc-root-setup.service` checks. Without any of
these, neither unit runs. The drop-ins leave the timer schedule unchanged.

The staged image is finalized at shutdown, so **any** clean reboot applies
it, including one done for some other reason. `bootc status` shows whether
an update is staged.

## Applying

Reboot when it suits you. To stage an update without waiting for the timer,
run `sudo bootc upgrade`, or run `ujust update-and-reboot` to stage an update
and get a reboot prompt. To see what would be fetched without staging it,
run `bootc upgrade --check`. `rpm-ostree cleanup
--pending` does not work on composefs, so a staged update cannot be
discarded that way.

## Rolling back

The previous deployment is kept. `sudo bootc rollback` makes it the default
for the next boot (discarding any staged update), then reboot; or pick the
previous entry in the boot menu (Fedora hides the menu; hold Shift or press
Esc during boot).

A rollback alone does not stick: the tracked tag still names the bad image,
so the next timer run stages it again and the next reboot returns to it.
Until the tag is fixed, `sudo bootc switch` to the good image's `@sha256:`
digest, which also pins it (`bootc upgrade` has nothing newer to fetch until
you switch back to a tag), or turn the timer off as below.

## Turning it off

`sudo systemctl disable --now bootc-fetch-apply-updates.timer` stops
background fetching on one host; the setting lives in `/etc` and survives
updates (but not a reboot on the transient `/etc` variant). A derived image can do the same with
`systemctl disable bootc-fetch-apply-updates.timer`, or override the timer's
schedule with its own drop-in in
`/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/`.
Give local drop-ins that add conditions a filename that sorts after the
image's `00-booted.conf`, which resets the stock conditions.
