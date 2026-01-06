<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github-production-user-asset-6210df.s3.amazonaws.com/167144/280001862-73a16cec-f7fd-4983-91ed-4fb8c372b578.png">
    <img alt="firezone logo" width="400" src="https://github-production-user-asset-6210df.s3.amazonaws.com/167144/280001875-267dad97-8f4e-4825-8581-71196ce01d3d.png">
  </picture>
</p>
<p align="center">
 <strong>A modern alternative to legacy VPNs.</strong>
</p>

---

<p align="center">
  <a href="https://discourse.firez.one/?utm_source=readme">
    <img src="https://img.shields.io/static/v1?logo=discourse&logoColor=959DA5&label=support%20forum&labelColor=333a41&message=join&color=611f69" alt="firezone Discourse" />
  </a>
  <a href="https://discord.gg/DY8gxpSgep">
    <img src="https://img.shields.io/discord/1228082899023298741?logo=discord&logoColor=959DA5&label=discord&labelColor=333a41&color=5865F2" alt="firezone Discord" />
  </a>
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <!--<a href="https://coveralls.io/github/firezone/firezone?branch=main">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=main" alt="Coverage Status" />
  </a>-->
  <img alt="GitHub commit activity" src="https://img.shields.io/github/commit-activity/m/firezone/firezone"/>
  <img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/firezone/firezone"/>
  <a href="https://twitter.com/intent/follow?screen_name=firezonehq">
    <img src="https://img.shields.io/twitter/follow/firezonehq?style=social&logo=twitter" alt="follow on Twitter">
  </a>
</p>

---

## Overview

[Firezone](https://www.firezone.dev/?utm_source=readme) is an open source
platform to securely manage remote access for any-sized organization. Unlike
most VPNs, Firezone takes a granular, least-privileged approach to access
management with group-based policies that control access to individual
applications, entire subnets, and everything in between.

<p align="center">
  <img width="1439" alt="architecture" src="https://github.com/firezone/firezone/assets/167144/48cd6a1e-2f3f-4ca7-969a-fc5b33e13d1c">
</p>

<!-- TODO: Record new overview video without so many colors so that the gif compressed better. This one (26 MB) was too large.
<p align="center">
  <img width="1200" alt="Firezone Overview" src="https://www.firezone.dev/images/overview-screencap.gif">
</p>
-->

## Features

Firezone is:

- **Fast:** Built on WireGuard® to be
  [3-4 times](https://wireguard.com/performance/) faster than OpenVPN.
- **Scalable:** Deploy two or more gateways for automatic load balancing and
  failover.
- **Private:** Peer-to-peer, end-to-end encrypted tunnels prevent packets from
  routing through our infrastructure.
- **Secure:** Zero attack surface thanks to Firezone's holepunching tech which
  establishes tunnels on-the-fly at the time of access.
- **Open:** Our entire product is open-source, allowing anyone to audit the
  codebase.
- **Flexible:** Authenticate users via email, Google Workspace, Okta, Entra ID,
  or OIDC and sync users and groups automatically.
- **Simple:** Deploy gateways and configure access in minutes with a snappy
  admin UI.

Firezone is **not:**

- A tool for creating bi-directional mesh networks
- A full-featured router or firewall
- An IPSec or OpenVPN server

## Contents of this repository

This is a monorepo containing the full Firezone product, marketing website, and
product documentation, organized as follows:

- [elixir](../elixir): Admin portal and control plane
- [rust/](../rust): Data plane and internal Rust libraries:
  - [rust/gateway](../rust/gateway): Gateway - Tunnel server based on WireGuard
    and deployed to your infrastructure.
  - [rust/relay](../rust/relay): Relay - STUN/TURN server to facilitate
    holepunching.
  - [rust/headless-client](../rust/headless-client): Cross-platform CLI client.
  - [rust/gui-client](../rust/gui-client): Cross-platform GUI client.
- [swift/](../swift/apple): macOS / iOS clients.
- [kotlin/](../kotlin/android): Android / ChromeOS clients.
- [website/](../website): Marketing website and product documentation.

## Quickstart

The quickest way to get started with Firezone is to sign up for an account at
[https://app.firezone.dev/sign_up](https://app.firezone.dev/sign_up?utm_source=readme).

Once you've signed up, follow the instructions in the welcome email to get
started.

## Frequently asked questions (FAQ)

### Can I self-host Firezone?

Our [license](#license) won't stop you from self-hosting the entire Firezone
product top to bottom, but our internal APIs are changing rapidly so we can't
meaningfully support self-hosting Firezone in production at this time.

If you're feeling especially adventurous and want to self-host Firezone for
**educational** or **hobby** purposes, follow the instructions to spin up a
local development environment in [CONTRIBUTING.md](CONTRIBUTING.md).

The latest published clients (on App Stores and on
[releases](https://github.com/firezone/firezone/releases)) are only guaranteed
to work with the managed version of Firezone and may not work with a self-hosted
portal built from this repository. This is because Apple and Google can
sometimes delay updates to their app stores, and so the latest published version
may not be compatible with the tip of `main` from this repository.

Therefore, if you're experimenting with self-hosting Firezone, you will probably
want to use clients you build and distribute yourself as well.

See the READMEs in the following directories for more information on building
each client:

- macOS / iOS: [swift/apple](../swift/apple)
- Android / ChromeOS: [kotlin/android](../kotlin/android)
- Windows / Linux: [rust/gui-client](../rust/gui-client)

### How long will 0.7 be supported until?

**Firezone 0.7 is currently end-of-life and has stopped receiving updates as of
January 31st, 2024.** It will continue to be available indefinitely from the
`legacy` branch of this repo under the Apache 2.0 license.

### How much does it cost?

We offer flexible per-seat monthly and annual plans for the cloud-managed
version of Firezone, with optional invoicing for larger organizations. See our
[pricing](https://www.firezone.dev/pricing?utm_source=readme) page for more
details.

Those experimenting with self-hosting can use Firezone for free without feature
or seat limitations, but we can't provide support for self-hosted installations
at this time.

## Documentation

Additional documentation on general usage, troubleshooting, and configuration
can be found at [https://www.firezone.dev/kb](https://www.firezone.dev/kb).

## Get Help

If you're looking for help installing, configuring, or using Firezone, check our
community support options:

1. [Discussion Forums](https://discourse.firez.one/?utm_source=readme): Ask
   questions, report bugs, and suggest features.
1. [Join our Discord Server](https://discord.gg/DY8gxpSgep): Join live
   discussions, meet other users, and chat with the Firezone team.
1. [Open a PR](https://github.com/firezone/firezone/issues): Contribute a bugfix
   or make a contribution to Firezone.

If you need help deploying or maintaining Firezone for your business, consider
[contacting our sales team](https://www.firezone.dev/contact/sales?utm_source=readme)
to speak with a Firezone expert.

See all support options on our [main support page](https://www.firezone.dev/support).

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=firezone/firezone&type=Date)](https://star-history.com/#firezone/firezone&Date)

## Developing and Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

Portions of this software are licensed as follows:

- All content residing under the "elixir/" directory of this repository, if that
  directory exists, is licensed under the "Elastic License 2.0" license defined
  in "elixir/LICENSE".
- All third party components incorporated into the Firezone Software are
  licensed under the original license provided by the owner of the applicable
  component.
- Content outside of the above mentioned directories or restrictions above is
  available under the "Apache 2.0 License" license as defined in "LICENSE".

WireGuard® is a registered trademark of Jason A. Donenfeld.
