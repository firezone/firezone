<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github-production-user-asset-6210df.s3.amazonaws.com/167144/280001862-73a16cec-f7fd-4983-91ed-4fb8c372b578.png">
    <img alt="firezone logo" width="400" src="https://github-production-user-asset-6210df.s3.amazonaws.com/167144/280001875-267dad97-8f4e-4825-8581-71196ce01d3d.png">
  </picture>
</p>
<p align="center">
 <strong>Secure remote access that's 3x faster than OpenVPN with zero-trust, peer-to-peer connections</strong>
</p>

<p align="center">
  <a href="https://www.firezone.dev/kb">Docs</a>
  | <a href="https://www.firezone.dev/kb/quickstart">Quickstart</a>
  | <a href="https://www.firezone.dev/kb/client-apps">Download Clients</a>
  | <a href="https://discourse.firez.one/?utm_source=readme">Community</a>
  | <a href="https://www.firezone.dev/support">Support</a>
</p>

---

<p align="center">
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <a href="https://coveralls.io/github/firezone/firezone?branch=legacy">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=legacy" alt="Coverage Status" />
  </a>
  <img alt="GitHub commit activity" src="https://img.shields.io/github/commit-activity/m/firezone/firezone"/>
  <img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/firezone/firezone"/>
  <a href="https://cloudsmith.com">
    <img src="https://img.shields.io/badge/OSS%20hosting%20by-cloudsmith-blue?logo=cloudsmith" alt="Cloudsmith" />
  </a>
  <a href="https://x.com/intent/follow?screen_name=firezonehq">
   <img alt="X (formerly Twitter) Follow" src="https://img.shields.io/badge/Follow-%40firezonehq-black?style=flat&logo=x" />

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

## Getting Started

### Option 1: Cloud (Recommended)
Get started in under 2 minutes with our managed solution.

[**Sign up free →**](https://app.firezone.dev/sign_up?utm_source=readme) *(No credit card required)*

Once you've signed up, follow the instructions in the welcome email to:
1. Install the client on your device
2. Connect to your first resource
3. Configure access policies

## Features

Firezone is:

- **Fast:** Built on WireGuard® to be
  [3-4 times](https://wireguard.com/performance/) faster than OpenVPN with sub-10ms latency overhead.
- **Scalable:** Deploy two or more gateways for automatic load balancing and
  failover. <!-- TODO: Add specific scaling numbers, e.g., "Tested with 10,000+ concurrent users" -->
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

## Performance & Security

### Performance Benchmarks
<!-- TODO: Add actual performance metrics from testing -->
- **Throughput:** Up to <!-- TODO: X Gbps --> per connection
- **Latency:** Sub-10ms overhead vs direct connection
- **Scaling:** Tested with <!-- TODO: X,000+ --> concurrent users
- **Memory Usage:** <!-- TODO: X GB --> recommended, <!-- TODO: Y GB --> minimum

### Security & Compliance
- **Encryption:** WireGuard® protocol with ChaCha20/Poly1305
- **Authentication:** Multiple SSO providers supported
- **Zero Trust:** All connections authenticated and authorized
- **Audit Logs:** <!-- TODO: Describe audit capabilities -->
- **Compliance:** <!-- TODO: List any compliance certifications -->

### Comparison with Alternatives

| Feature | Legacy VPN | Firezone |
|---------|------------|----------|
| Setup Time | Hours | 2 minutes |
| Performance | Baseline | 3x faster |
| Architecture | Hub-spoke | Peer-to-peer |
| Zero Trust | ❌ | ✅ |
| Open Source | ❌ | ✅ |

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
  - [rust/headless-client](../rust/headless-client): Cross-platform CLI client.
  - [rust/gui-client](../rust/gui-client): Cross-platform GUI client.
- [swift/](../swift/apple): macOS / iOS clients.
- [kotlin/](../kotlin/android): Android / ChromeOS clients.
- [website/](../website): Marketing website and product documentation.

## License & Pricing

### Open Source (Apache 2.0 + Elastic 2.0)
- ✅ Full source code available for audit
- ✅ Self-hosting allowed (educational/hobby use)
- ✅ Community support via Discord and forums
- ⚠️ Production self-hosting not officially supported

### Cloud - Usage Based
- ✅ Managed hosting with SLA
- ✅ Production-ready with enterprise support
- ✅ Automatic updates and maintenance
- 💰 Starting free, then per-seat pricing
- [**View detailed pricing →**](https://www.firezone.dev/pricing?utm_source=readme)

**Pricing Overview:**
- **Starter:** Free for <!-- TODO: X --> users/month
- **Team:** $<!-- TODO: X -->/user/month for advanced features
- **Enterprise:** Custom pricing with SSO, compliance, priority support

### Enterprise Features
- 🔐 **SSO/SAML** - Integrate with your identity provider
- 📝 **Audit Logs** - Complete activity tracking for compliance
- 🏢 **Priority Support** - Dedicated team for your organization
- 🎯 **Custom Integrations** - Tailored solutions for your infrastructure

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

See our detailed [License & Pricing](#license--pricing) section above for comprehensive pricing information.

### Migrating from Other VPNs

**Coming from OpenVPN, ZeroTier, or Tailscale?**
<!-- TODO: Add specific migration guides -->
- [Migrate from OpenVPN →](<!-- TODO: Add migration guide link -->)
- [Migrate from ZeroTier →](<!-- TODO: Add migration guide link -->)
- [Migrate from Tailscale →](<!-- TODO: Add migration guide link -->)
- [General VPN Migration Guide →](<!-- TODO: Add general guide link -->)

**Migration typically involves:**
1. Installing Firezone alongside your current solution
2. Configuring equivalent access policies
3. Testing connectivity with a subset of users
4. Gradually migrating users and decommissioning old infrastructure

## Documentation

Additional documentation on general usage, troubleshooting, and configuration
can be found at [https://www.firezone.dev/kb](https://www.firezone.dev/kb).

## Join Our Community

### Quick Ways to Contribute
- ⭐ **Star this repo** to show support and stay updated
- 🐛 **Report bugs** or request features via [GitHub Issues](https://github.com/firezone/firezone/issues)
- 💬 **Join our [Discord](https://discord.gg/DY8gxpSgep)** for live discussions and community support
- 🗣️ **Join the [Discussion Forums](https://discourse.firez.one/?utm_source=readme)** for longer-form conversations

### For Contributors
- 🎯 **Check out [good first issues](https://github.com/firezone/firezone/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)** to get started
- 📖 **Read our [contribution guide](CONTRIBUTING.md)** for development setup
- 🏗️ **See the [development environment setup](CONTRIBUTING.md)** to start coding
- 🔄 **Submit a pull request** - all contributions welcome!

**Recognition:** All contributors get <!-- TODO: Describe contributor recognition/rewards -->!

## Get Help

**Community Support (Free)**
- [Discord Server](https://discord.gg/DY8gxpSgep) - Live chat with users and team
- [Discussion Forums](https://discourse.firez.one/?utm_source=readme) - Detailed Q&A
- [GitHub Issues](https://github.com/firezone/firezone/issues) - Bug reports and feature requests

**Business Support**
- [Contact Sales](https://www.firezone.dev/contact/sales?utm_source=readme) for enterprise deployment help
- [Support Portal](https://www.firezone.dev/support) for paid customers
- Priority support included with Team and Enterprise plans

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=firezone/firezone&type=Date)](https://star-history.com/#firezone/firezone&Date)

## Developing and Contributing

We welcome contributions of all kinds! See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Development environment setup
- Code style guidelines
- Testing procedures
- Pull request process

## Security

Security is fundamental to Firezone. See [SECURITY.md](SECURITY.md) for:
- Security disclosure process
- Vulnerability reporting
- Security best practices
- Audit information

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
