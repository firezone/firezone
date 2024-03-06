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
  <a href="https://github.com/firezone/firezone/releases">
    <img src="https://img.shields.io/github/v/release/firezone/firezone?color=%23999">
  </a>
  <a href="https://discourse.firez.one/?utm_source=readme">
    <img src="https://img.shields.io/static/v1?logo=discourse&logoColor=959DA5&label=support%20forum&labelColor=333a41&message=join&color=611f69" alt="firezone Discourse" />
  </a>
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <a href="https://coveralls.io/github/firezone/firezone?branch=legacy">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=legacy" alt="Coverage Status" />
  </a>
  <img alt="GitHub commit activity" src="https://img.shields.io/github/commit-activity/m/firezone/firezone"/>
  <img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/firezone/firezone"/>
  <a href="https://cloudsmith.com">
    <img src="https://img.shields.io/badge/OSS%20hosting%20by-cloudsmith-blue?logo=cloudsmith" alt="Cloudsmith">
  </a>
  <a href="https://twitter.com/intent/follow?screen_name=firezonehq">
    <img src="https://img.shields.io/twitter/follow/firezonehq?style=social&logo=twitter" alt="follow on Twitter">
  </a>
</p>

---

**Note**: 🚧 The `main` branch is undergoing major restructuring in preparation
for the release of Firezone 1.0 🚧.

See the [`legacy` branch](https://github.com/firezone/firezone/tree/legacy) if
you're looking for Firezone 0.7.

[Read the 1.0 announcement for more](https://www.firezone.dev/blog/firezone-1-0).

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

<!-- TODO: New intro usage video
![firezone-usage](https://user-images.githubusercontent.com/52545545/147392573-fe4cb936-a0a8-436f-a69b-c0a9587de58b.gif)
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

- [elixir](../elixir): Control plane and internal Elixir libraries:
  - [elixir/apps/web](../elixir/apps/web): Admin UI
  - [elixir/apps/api](../elixir/apps/api): API for Clients, Relays and Gateways.
- [rust/](../rust): Data plane and internal Rust libraries:
  - [rust/gateway](../rust/gateway): Gateway - Tunnel server based on WireGuard
    and deployed to your infrastructure.
  - [rust/relay](../rust/relay): Relay - STUN/TURN server to facilitate
    holepunching.
  - [rust/linux-client](../rust/linux-client): Linux CLI client.
  - [rust/gui-client](../rust/gui-client): Cross-platform GUI client.
- [swift/](../swift/apple): macOS / iOS clients.
- [kotlin/](../kotlin/android): Android / ChromeOS clients.
- [website/](../website): Marketing website and product documentation.
- [terraform/](../terraform): Terraform files for our cloud infrastructure:
  - [terraform/modules/gateway-google-cloud-compute](../terraform/modules/gateway-google-cloud-compute):
    Example Terraform module for deploying a Gateway to a Google Compute
    Regional Instance Group.

## Quickstart

Firezone 1.x is currently accepting early access signups for closed testing.
Fill out the
[early access form](https://www.firezone.dev/product/early-access?utm_source=readme)
to request access and we'll be in touch!

## Frequently asked questions (FAQ)

### Can I self-host Firezone?

Our [license](#license) won't stop you from self-hosting the entire Firezone
product top to bottom, but we can't commit the resources to make this a smooth
experience and therefore don't support self-hosting the control plane at this
time.

If you have a business case requiring an on-prem installation of Firezone please
[get in touch](https://www.firezone.dev/contact/sales?utm_source=readme).

If you're feeling especially adventurous and want to self-host Firezone for
**educational** or **recreational** purposes, you'll want to build and
distribute the clients from source to ensure they remain locked to a version
compatible with your self-hosted control plane. Unfortunately, the following
clients must be distributed through proprietary app stores due to restrictions
imposed by Apple and Google:

- macOS
- iOS
- Android / ChromeOS

Because it's impossible to select which client version to install from a
particular app store, building and distributing Firezone from source is the only
to way self-host Firezone at this time.

Otherwise, if you're hobbyist or developer and are looking to spin it up locally
to contribute or experiment with, see [CONTRIBUTING.md](CONTRIBUTING.md).

### How do I upgrade from 0.7?

Unfortunately, you can't. The good news is Firezone 1.x is _much_ easier to
setup and manage than 0.x and so you probably don't need to.

### How long will 0.7 be supported until?

**Firezone 0.7 is currently end-of-life and will stop receiving updates after
January 31st, 2024.** It will continue to be available indefinitely from the
`legacy` branch of this repo under the Apache 2.0 license.

### What's your pricing structure like?

Please see our pricing page at
https://www.firezone.dev/pricing?utm_source=readme

## Documentation

Additional documentation on general usage, troubleshooting, and configuration
can be found at [https://docs.firezone.dev](https://docs.firezone.dev).

## Get Help

If you're looking for help installing, configuring, or using Firezone, check our
community support options:

1. [Discussion Forums](https://discourse.firez.one/?utm_source=readme): Ask
   questions, report bugs, and suggest features.
1. [Public Slack Group](https://join.slack.com/t/firezone-users/shared_invite/zt-111043zus-j1lP_jP5ohv52FhAayzT6w):
   Join live discussions, meet other users, and get to know the contributors.
1. [Open a PR](https://github.com/firezone/firezone/issues): Contribute a bugfix
   or make a contribution to Firezone.

<!-- TODO
If you need help deploying or maintaining Firezone for your business, consider
[contacting us about our paid support plan](https://www.firezone.dev/contact/sales?utm_source=readme).
-->

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
