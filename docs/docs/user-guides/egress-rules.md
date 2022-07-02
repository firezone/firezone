---
title: Egress Rules
sidebar_position: 3
---

Firezone supports egress filtering controls to explicitly DROP or ACCEPT packets
via the kernel's netfilter system. By default, all traffic is allowed.

The Allowlist and Denylist support both IPv4 and IPv6 CIDRs and IP addresses.
When adding a rule, you may optionally scope it to a user which applies the
rule to all their devices.

![firewall rules](https://user-images.githubusercontent.com/52545545/153467657-fe287f2c-feab-41f5-8852-6cefd9d5d6b5.png)
