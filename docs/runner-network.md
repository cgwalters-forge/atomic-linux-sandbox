# Job VM network isolation

> This text is LLM generated.

CI jobs run untrusted code in per-job VMs. `runner-network.service` gives
those VMs a bridge of their own, `runnerbr0`, and an nftables table,
`inet runner_network`, so that a job can reach the forge, registries and
the service endpoints the operator lists, and nothing else: not the LAN,
not the tailnet, not link-local metadata addresses and not the host's own
services. That stops a compromised or malicious job from scanning or
attacking other machines, or using the host as a stepping stone.

The unit is enabled but inert: it is skipped until
`/etc/atomic-linux/runner-network.conf` exists. Nothing in the image names
an address to allow; all of them come from that file.

## Configuration

Start from the example, whose addresses are documentation placeholders:

```sh
install -D -m 0644 /usr/share/atomic-linux/runner-network.conf.example /etc/atomic-linux/runner-network.conf
systemctl start runner-network.service
```

After editing the file, `systemctl reload runner-network.service` replaces
the rules atomically and leaves running VMs attached. Changing `address`
needs a restart, which deletes the bridge and so detaches every VM.

Each line is `KEY VALUE`, IPv4 only, and `#` starts a comment:

| Key | Value |
| --- | --- |
| `address` | The bridge's own address and prefix (default `10.231.0.1/24`); job VMs use it as their gateway |
| `dns` | A resolver address job VMs may query on port 53, TCP and UDP; at least one is required |
| `allow` | An address or CIDR job VMs may reach on any port |

At most 256 `dns` and `allow` entries are accepted. List private service
endpoints (on the LAN or the tailnet) as single addresses, `/32`; a broad
entry such as `0.0.0.0/0` would open the LAN as well, and a prefix with host
bits set (`192.168.1.5/16`) is refused as a likely typo. Forges publish their
ranges, e.g. GitHub's `meta` API; refresh the file when they change.

A malformed file is refused before anything changes on the host: the
ruleset is loaded before the bridge is created, all or nothing.
`bash /usr/libexec/atomic-linux/runner-network ruleset FILE | nft -c -f -`
checks a file without loading it.

## Rules

Only traffic entering or leaving `runnerbr0` is matched; the host's own
traffic is unaffected.

- From a job VM, forwarded: DNS to a `dns` resolver and anything to an
  `allow` entry are accepted and masqueraded behind the host. Everything
  else is dropped, which covers RFC 1918, link-local (169.254.0.0/16), the
  tailnet's CGNAT range (100.64.0.0/10), all IPv6 and sources outside the
  bridge's subnet.
- From a job VM to the host itself: dropped, apart from DNS when a `dns`
  entry is a resolver the host runs on the bridge address (none does by
  default; systemd-resolved listens on loopback only).
- Into the bridge: only replies to connections the VMs opened.

The `runner` firewalld zone accepts `runnerbr0` so that firewalld does not
interfere; the table's drops apply whatever firewalld accepts. The zone
ships even while the service is inert, which is harmless while no
`runnerbr0` exists, but it means the table is the only filter: never create
the bridge by other means. Starting the service sets `net.ipv4.ip_forward=1`
and stopping it leaves that on; firewalld still rejects forwarding between
its own zones.

`nft list table inet runner_network` shows the rules with counters for each
drop.

## Not covered

- Addressing: the bridge serves no DHCP, so the VM launcher gives each VM an
  address in the bridge's subnet with the bridge address as gateway.
- VM to VM traffic on the bridge is switched, not filtered, so concurrent
  job VMs can reach each other, unless `br_netfilter` is loaded (k3s
  enabled), in which case the table drops it.
- Allowlisted destinations are trusted on every port.
