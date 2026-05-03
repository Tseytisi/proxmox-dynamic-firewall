# Unofficial Proxmox dynamic firewall service
Dynamically update Proxmox firewall IP entries using DNS.

Small script that periodically queries a given domain name, and resolves its IP-address. If the IP-address changes, the dynamic firewall entries for that domain are automatically updated. Handy for IP whitelists that contain non-static public IP-addresses. Best combined with DDNS.

- Dynamic entries are visible and updateable from the Proxmox web GUI
- Only entries explicitly marked dynamic are updated, even if other entries contain the same IP-address
- Works with any 'A' and 'AAAA' type DNS record, even for private-range IP-addresses
- Only writes updates if an IP-address actually changed. The firewall is not reloaded more than necessary.
- Disabled firewall entries are not updated

_I am not affiliated with the Proxmox team. This is not official software and comes with no warranty. Proxmox updates may break this software._

_IPv6 is not fully implemented yet_

# How to use
After [installation](#how-to-install), in either the web interface or the `.fw` files on a node (located at `/etc/pve/firewall/`):

Add the following to the comment of an entry: `[DYN-IP <type> <domain>]`, where:
- `type` is either `A` (IPv4) or `AAAA` (IPv6)
- `domain` is any DNS-resolvable domain or subdomain

Other comments are still allowed.

Example (using private IP-ranges as example):
```
[IPSET remote_engineers]

10.20.30.40 # John's house [DYN-IP A example.com]
10.0.0.50 # Static entry [regular comments in square-brackets are no problem]
2001:db8::ff00:42:8329 # Alice's proxy [DYN-IP AAAA proxy.alice.example]

[RULES]

IN ACCEPT -p tcp -dport 8080 -source 10.10.60.10 -log nolog # [DYN-IP A home.dave.example]
```

There is no need to have the DNS record to point to an active service. An entry like `[DYN-IP A temp-location1.thecompany.com]` works completely fine even if the IP-address would be of no use in a web-browser or other application.

# How to install
The "service" consists of a single Bash script that needs no other resources to run. A systemd service and timer are included in the repository, but the only requirement is that the `pvedynfw.sh` script is executed periodically. Cron or any task scheduler would suffice too.

Basic installation places `pvedynfw.sh` in `/usr/local/bin/`, and both `pvedynfw.service` and `pvedynfw.timer` in `/etc/systemd/system/`. After updating files for systemd, make sure to run `systemctl daemon-reload`. Then start the timer (and enable it for after reboots) with `systemctl enable --now pvedynfw.timer`.

The script must be run as `root`, as the firewall files are not writeable by another user.
- It is possible to run the script as a less-privileged user if some other script or user updates the firewall files manually. In this case, `$NO_OVERWRITE` should be set to `true`, which will write updated files to `/tmp/`.
    - The user `www-data` is the only non-root user with read access (and does not have write access). Any other user would also need some other way to read the current firewall files.

The script depends on a few commands to work (all included in a basic PVE installation as far as I'm aware):
- Bash that supports POSIX Extended Regular Expressions
- `dig` - For DNS lookups
- `awk`
- `grep` (GNU), must support `-P` Perl regular expressions

The script logs any errors to STDERR. When running through systemd, these logs are visible through `journalctl -u pvedynfw.service`.

# Behaviour
- What if a query fails?
    - If the DNS query does not return a valid IPv4/IPv6 address, either because the DNS server is unreachable or because the domain could not be resolved, those entries in the firewall are left as-is. Other dynamic IP entries will still be checked.
- What if the query returns more than one address?
    - By default, an error is logged and the firewall remains unchanged. It is possible to instead use the first address returned by the query, but this is disabled by default. It is (currently) not possible to use all returned IP-addresses.
- What if the firewall rule contains more than one IP? Which one will be updated?
    - The first IP-address of the target type in the rule will be updated. E.g:
        - If the rule of a `[DYN-IP A ...]` contains more than one IPv4 address, the first IPv4 address will be updated
        - If the rule of a `[DYN-IP A ...]` contains first an IPv6 address and then an IPv4 address, the IPv4 address will be updated
        - If the rule of a `[DYN-IP AAAA ...]` contains more than one IPv6 address, the first IPv6 address will be updated
        - If the rule of a `[DYN-IP AAAA ...]` contains first an IPv4 address and then an IPv6 address, the IPv6 address will be updated

# Disclaimer
_This software comes with absolutely no warranty._ A dynamic firewall is more error-prone than a static one, and this system is vulnerable to DNS attacks and DNS cache poisoning. Though the latter concern can be reduced by using DNSSEC. The attacker would also need to know the exact domain the script queries. And then still, a firewall is (almost) never the only line of defense. Security concerns are small, but be aware of them.

This script was tested on Proxmox Virtual Environment 9.1, for a single node. It was not tested on a multi-node PVE datacentre. It should work on Proxmox Backup Server too, but this was also not tested.

IPv6 was also not thoroughly tested, though should work very similarly to IPv4.

