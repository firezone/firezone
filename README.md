<p align="center">
  <img src="https://user-images.githubusercontent.com/52545545/144147936-39f3e416-8ba0-4f24-915e-f0515f85bb64.png" alt="firezone logo" width="305"/>
</p>
<p align="center">
  <a href="https://github.com/firezone/firezone/releases">
    <img src="https://img.shields.io/github/v/release/firezone/firezone?color=%23999">
  </a>
  <a href="https://discourse.firez.one">
    <img src="https://img.shields.io/static/v1?logo=discourse&logoColor=959DA5&label=support%20forum&labelColor=333a41&message=join&color=611f69" alt="firezone Discourse" />
  </a>
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <a href="https://coveralls.io/github/firezone/firezone?branch=master">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=master" alt="Coverage Status" />
  </a>
  <img alt="GitHub commit activity" src="https://img.shields.io/github/commit-activity/m/firezone/firezone"/>
  <img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/firezone/firezone"/>
  <a href="https://twitter.com/intent/follow?screen_name=firezonehq">
    <img src="https://img.shields.io/twitter/follow/firezonehq?style=social&logo=twitter" alt="follow on Twitter">
  </a>
</p>

## [Firezone](https://www.firezone.dev) is a self-hosted VPN server and Linux firewall

* Manage remote access through an intuitive web interface and CLI utility.
* [Deploy on your own infrastructure](https://docs.firezone.dev/docs/deploy) to keep control of your network traffic.
* Built on [WireGuard®](https://www.wireguard.com/) to be stable, performant, and lightweight.

![Firezone Architecture](https://user-images.githubusercontent.com/52545545/173246039-a1b37ef2-d885-4535-bca7-f5cd57da21a2.png)

## Get Started

Follow our [deploy guide](https://docs.firezone.dev/docs/deploy) to install your self-hosted instance of Firezone.

Or, if you're on a [supported platform](https://docs.firezone.dev/docs/deploy/supported-platforms/), try our one-line install script:

```bash
bash <(curl -Ls https://github.com/firezone/firezone/raw/master/scripts/install.sh)
```

Using Firezone for your team? Take a look at our [business tier](https://www.firezone.dev/pricing).

## What is Firezone?

[Firezone](https://www.firezone.dev) is a Linux package to manage your WireGuard® VPN through a simple web interface.

![firezone-usage](https://user-images.githubusercontent.com/52545545/147392573-fe4cb936-a0a8-436f-a69b-c0a9587de58b.gif)

### Features

* **Fast:** Uses WireGuard® to be [3-4 times](https://wireguard.com/performance/) faster than OpenVPN.
* **SSO Integration:** Authenticate using any identity provider with an OpenID Connect (OIDC) connector.
* **No dependencies:** All dependencies are bundled thanks to
[Chef Omnibus](https://github.com/chef/omnibus).
* **Simple:** Takes minutes to set up. Manage via a simple CLI.
* **Secure:** Runs unprivileged. HTTPS enforced. Encrypted cookies.
* **Firewall included:** Uses Linux [nftables](https://netfilter.org) to block unwanted egress traffic.

### Anti-features

Firezone is **not:**

* An inbound firewall
* A tool for creating mesh networks
* A full-featured router
* An IPSec or OpenVPN server

## Documentation

Additional documentation on general usage, troubleshooting, and configuration can be found at
[https://docs.firezone.dev](https://docs.firezone.dev).

## Get Help

If you're looking for help installing and configuring Firezone, we're happy to
help:

* [Discussion Forums](https://discourse.firez.one/): ask questions, report bugs, and suggest features
* [Community Slack](https://www.firezone.dev/slack): join discussions, meet other users, and meet the contributors
* [Email Us](mailto:team@firezone.dev): we're always happy to chat

## Developing and Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE).

WireGuard® is a registered trademark of Jason A. Donenfeld.
