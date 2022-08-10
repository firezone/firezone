---
title: Two-Factor authentication (2FA) with WireGuard
description: A short description of this page
keywords: [keywords, describing, the main topics]
sidebar_position: 1
---

WireGuard is a modern VPN that aims to be faster, leaner, and simpler than
existing protocols like OpenVPN and IPSec. There’s detailed documentation on
the [WireGuard website](https://www.wireguard.com/)
explaining how it accomplishes these feats.

Adding a second factor to WireGuard’s authentication mechanism
(public-private keys) can be desired in environments requiring
additional security. Firezone is built on top of WireGuard to enable
functionality like two-factor authentication (2FA) and single sign-on (SSO).

## Why WireGuard with 2FA?

WireGuard’s functionality is well-defined and intentionally limited.
The protocol only supports UDP and is “cryptographically opinionated,”
lacking the option to switch between different cipher and protocol suites.
Similarly, key and identity management is outside the scope of the protocol.

This means a peer that leaks its WireGuard configuration file can give an
attacker full access to the private network. Detecting compromised keys
is also challenging - requiring additional tooling or reconciling traffic logs.

2FA strengthens access security by requiring an additional authentication factor
to verify identity. 2FA can mitigate unwanted access by attackers obtaining
credentials through phishing, brute-force attacks, or credential leaks.

## 2FA/MFA using Firezone

Firezone makes WireGuard more manageable for individuals, teams, and large
enterprises. In the current version, WireGuard configs are mapped to devices,
which are associated to a user.

In Firezone, user accounts can be secured through username/password or by
integrating a single sign-on provider. MFA can be enforced by adding a time-based
one-time password (TOTP). See
[our documentation](https://docs.firezone.dev/authenticate)
for details on how to set up Firezone with 2FA/MFA.
