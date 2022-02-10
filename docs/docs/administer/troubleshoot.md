---
layout: default
title: Troubleshoot
nav_order: 5
parent: Administer
---
---

For any problems that arise, a good first bet is to check the Firezone logs.

To view Firezone logs, run `sudo firezone-ctl tail`.

## Debugging Connectivity Issues

Most connectivity issues with Firezone are caused by other `iptables` or
`nftables` rules which interfere with Firezone's operation.

If you're experiencing connectivity issues, check to ensure the `iptables`
ruleset is empty:

```text
root@demo:~# iptables -L
Chain INPUT (policy ACCEPT)
target     prot opt source               destination

Chain FORWARD (policy ACCEPT)
target     prot opt source               destination

Chain OUTPUT (policy ACCEPT)
target     prot opt source               destination
```

Firezone ships with an embedded `nft` utility at
`/opt/firezone/embedded/sbin/nft` that can be used to view and debug
the kernel's `nftables` ruleset. On a fresh Firezone installation,
your nftables ruleset should look something like this:

```text
root@demo:~# /opt/firezone/embedded/sbin/nft list ruleset
table inet firezone {
  chain forward {
    type filter hook forward priority filter; policy accept;
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "enp1s0" masquerade random,persistent
    oifname "enp6s0" masquerade random,persistent
  }
}
```

## Need additional help?

If you're looking for help installing, configuring, or using Firezone, we're
happy to help.

* [Discussion Forums](https://discourse.firez.one/): ask questions, report bugs, and suggest features
* [Public Slack Group](https://join.slack.com/t/firezone-users/shared_invite/zt-111043zus-j1lP_jP5ohv52FhAayzT6w): join discussions, meet other users, and meet the contributors
* [Email Us](mailto:team@firez.one): we're always happy to chat
