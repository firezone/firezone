---
layout: default
title: Firewall Rules
nav_order: 3
parent: User Guides
---
---

Firezone supports egress filtering controls to explicitly DROP or ACCEPT packets
via the kernel's netfilter system. By default, all traffic is allowed.

The Allowlist and Denylist support both IPv4 and IPv6 CIDRs and IP addresses.

![firewall rules](https://user-images.githubusercontent.com/52545545/152583668-99077cb3-f83b-4ca4-8641-2e8b2ae5d061.png)

## Viewing the Firezone nftables Ruleset

Firezone ships with an embedded `nft` utility at
`/opt/firezone/embedded/sbin/nft` that can be used to view and debug
the kernel's nftables ruleset. For example:

```text
root@demo:~# /opt/firezone/embedded/sbin/nft list table inet firezone
table inet firezone {
  chain forward {
    type filter hook forward priority filter; policy accept;
    ip daddr 0.0.0.0/0 drop
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "enp1s0" masquerade random,persistent
    oifname "enp6s0" masquerade random,persistent
  }
}
```
