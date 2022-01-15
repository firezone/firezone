<p align="center">
  <img src="https://user-images.githubusercontent.com/52545545/144147936-39f3e416-8ba0-4f24-915e-f0515f85bb64.png" alt="firezone logo" width="500"/>
</p>
<p align="center">
  <a href="https://github.com/firezone/firezone/releases">
    <img src="https://img.shields.io/github/v/release/firezone/firezone?color=%23999">
  </a>
  <a href="https://e04kusl9oz5.typeform.com/to/zahKLf3d">
    <img src="https://img.shields.io/static/v1?logo=openbugbounty&logoColor=959DA5&label=feedback&labelColor=333a41&message=submit&color=3AC358" alt="submit feedback" />
  </a>
  <a href="https://discourse.firez.one">
    <img src="https://img.shields.io/static/v1?logo=discourse&logoColor=959DA5&label=forum&labelColor=333a41&message=join&color=611f69" alt="firezone Discourse" />
  </a>
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <a href="https://coveralls.io/github/firezone/firezone?branch=master">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=master" alt="Coverage Status" />
  </a>
  <a href="https://twitter.com/intent/follow?screen_name=firezonevpn">
    <img src="https://img.shields.io/twitter/follow/firezonevpn?style=social&logo=twitter" alt="follow on Twitter">
  </a>
</p>


<p align="center">
  <strong>A self-managed <a href="https://www.wireguard.com/">WireGuard</a>-based VPN server and Linux firewall designed for simplicity and security.</strong>
</p>

<hr>

![Architecture](https://user-images.githubusercontent.com/52545545/147286088-08b0d11f-d81d-4622-8145-179071d2f0fb.png)

# Get started

Follow our installation guide at https://docs.firez.one/get-started to install your self-hosted instance of Firezone. 

Additional documentation on general usage, troubleshooting, and configuration can be found at https://docs.firez.one/.


# What is Firezone?

[Firezone](https://www.firez.one/) is a Linux package to manage your WireGuard VPN through a simple web interface.

![firezone-usage](https://user-images.githubusercontent.com/52545545/147392573-fe4cb936-a0a8-436f-a69b-c0a9587de58b.gif)

## Features

- **Fast:** Uses WireGuard to be [3-4 times](https://wireguard.com/performance/) faster than OpenVPN.
- **No dependencies:** All dependencies are bundled thanks to
    [Chef Omnibus](https://github.com/chef/omnibus).
- **Simple:** Takes minutes to set up. Manage via a simple CLI.
- **Secure:** Runs unprivileged. HTTPS enforced. Encrypted cookies.
- **Firewall included:** Uses Linux [nftables](https://netfilter.org) to block
    unwanted egress traffic.

## Anti-features

Firezone is **not:**

- An inbound firewall
- A tool for creating mesh networks
- A full-featured router
- An IPSec or OpenVPN server

# Get Help

If you're looking for help installing and configuring Firezone, we're happy to
help:

* [Discussion Forums](https://discourse.firez.one/)
* [Public Slack Group](https://join.slack.com/t/firezone-users/shared_invite/zt-111043zus-j1lP_jP5ohv52FhAayzT6w)
* [Email Us](mailto:team@firez.one)

# Developing and Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

# Security

See [SECURITY.md](SECURITY.md).

# License

See [LICENSE](LICENSE).

WireGuard® is a registered trademark of Jason A. Donenfeld.
