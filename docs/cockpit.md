# Cockpit: downstream-only opt-in

> This text is LLM generated.

Both variants carry `cockpit-ws`, `cockpit-system`, `cockpit-podman`,
`cockpit-storaged` and `cockpit-networkmanager`.
They provide a privileged host administration console, not a preconfigured
remote-access service. `cockpit.socket` is disabled, not masked. The early
vendor preset `00-atomic-linux-cockpit.preset` also disables it on first-boot
`preset-all`; this prevents an unsolicited web login listener before the owner
has configured authentication and network access. There is no generic-image
tailnet zone, interface binding, enrollment or Cockpit firewall opening.
The default zone still permits only SSH and Tailscale's UDP transport.

These are not just static web pages: hard dependencies include cockpit-bridge
and udisks2, even with weak dependencies disabled. The Cockpit VM page
(`cockpit-machines`) is not installed: it requires additional libvirt drivers
and the default NAT network. A derived image that wants the page can add
`cockpit-machines` to its package drop-ins. Review the resulting libvirt
services and networks separately; disabling Cockpit does not disable them.

## Plan access in the derived image

Keep users, VPN enrollment, device identity, tailnet access policy and firewall
configuration in the downstream repository or host provisioning. Do not embed
enrollment keys, passwords or TLS private keys in a public image. Use restricted
tailnet grants/ACLs for the intended administrators and destination TCP 9090;
membership of a tailnet alone is not authorization to administer every host.

Cockpit authenticates through the host's PAM stack and uses polkit for
privileged actions. Configure a dedicated non-root administrator with only
the required privileges, a strong authentication policy (MFA where supported
by that PAM setup), and review `/etc/cockpit/disallowed-users`. The image's
SSH key-only policy does **not** enforce Cockpit's PAM policy. Do not enable
root web login or empty passwords. Test the intended PAM authentication before
allowing remote access.

Use HTTPS. Provision a certificate and private key for the downstream DNS name
under `/etc/cockpit/ws-certs.d/`, with private material readable only by the
necessary service/root, following the [Cockpit TLS documentation](https://cockpit-project.org/guide/latest/https).
Trust the issuing CA on clients and verify the name and certificate; do not
bypass browser warnings or allow unencrypted remote login. Tailnet encryption
does not replace server authentication and secure application configuration.

## Tailnet-only firewall policy (downstream)

The concrete threat is reaching the privileged console from a LAN/public
interface, or from unauthorized tailnet peers. An owner can configure a
dedicated firewalld zone without changing the default zone, for example:

```sh
sudo firewall-cmd --permanent --new-zone=cockpit-tailnet
sudo firewall-cmd --permanent --zone=cockpit-tailnet --add-interface=tailscale0
sudo firewall-cmd --permanent --zone=cockpit-tailnet --add-service=cockpit
sudo firewall-cmd --reload
```

This is an example for a new downstream zone; reconcile existing zones and
NetworkManager connection bindings first. Never add `cockpit` or `9090/tcp`
to the default/LAN zone, and never assign `tailscale0` to `trusted` just to
reach Cockpit. Do not open public router ports or use Funnel for this console.

**The zone binding alone is not an isolation guarantee.** In its default
netfilter mode, tailscaled installs its own input/forward rules, including
accepts for traffic arriving on `tailscale0`. These may bypass firewalld zone
restrictions depending on the backend, hook priority and rule ordering.
Tailnet peer restrictions must be enforced in tailnet policy, not inferred
from this zone. If downstream chooses `tailscale set --netfilter-mode=off`,
it takes responsibility for the complete IPv4/IPv6 Tailscale firewall,
anti-spoofing and any forwarding/NAT policy; do not change this blindly to
make a zone example appear sufficient. See [Tailscale netfilter modes](https://tailscale.com/kb/1294/firewall-mode).

Before leaving access enabled, inspect **effective runtime** state, not just
permanent XML (and repeat after reboot, firewalld reload and tailscaled restart):

```sh
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all-zones
sudo firewall-cmd --list-all-policies
sudo nft list ruleset
sudo iptables-save
sudo ip6tables-save
sudo ss -lntp 'sport = :9090'
```

Use the tools matching the actual tailscaled/firewalld backends; an absent
iptables tool is not evidence that no rules exist. Trace IPv4 and IPv6 input
paths, including tailscaled's chains, early accepts, direct/rich rules,
policies, source bindings and other managers. Check every LAN/public interface
and address family. No wildcard allow or competing rule may expose 9090 there.

Keep the socket stopped during initial inspection. In a disposable test
deployment, enable it temporarily only after reviewing the rules, then test
HTTPS from an authorized tailnet client (success with valid TLS/authentication),
an unauthorized tailnet client (failure), and separate LAN/public clients
(failure) over **both IPv4 and IPv6** where configured. Test all applicable host
addresses, not only a DNS name. Stop immediately if isolation fails; lack of
an IPv6 test path is a gap, not proof of IPv6 isolation. Offline image tests
check configuration and presets, not packet handling or real tailnet traffic.

## Enable and disable

Only after the downstream checks above, opt in on that host:

```sh
sudo systemctl enable --now cockpit.socket
sudo systemctl status cockpit.socket
```

For a derived image that must survive a later `preset-all`, provide an earlier
downstream vendor preset (for example `00-aaa-cockpit.preset` containing
`enable cockpit.socket`) and explicitly enable the socket at image build time.
Do not change the generic preset. Inspect preset ordering and re-test first
boot in the derived image; an explicit enable alone is undone by preset-all.

To withdraw access, stop the listener **and any already activated service**:

```sh
sudo systemctl disable --now cockpit.socket
sudo systemctl stop cockpit.service
sudo firewall-cmd --permanent --zone=cockpit-tailnet --remove-service=cockpit
sudo firewall-cmd --reload
sudo ss -lntp 'sport = :9090'
```

Remove any downstream enabling preset too, and review active sessions. Verify
the listener is gone and repeat negative reachability checks. A firewall rule
removal alone need not terminate established connections, and stopping only
the socket need not stop an already running Cockpit service.
