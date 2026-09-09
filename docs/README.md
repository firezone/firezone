<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/cae1e42d-78cb-4368-87b0-06b621962233">
    <img alt="Firezone logo" width="400" src="https://github.com/user-attachments/assets/81a90197-2250-4f5c-8195-43e25fb0b0b8">
  </picture>
</p>
<p align="center">
  <strong>Blazing-fast remote access with identity-based policies, attested device trust, and detailed audit logs</strong>
</p>

<p align="center">
  <a href="https://www.firezone.dev/kb">Documentation</a>
  | <a href="https://www.firezone.dev/kb/quickstart">Quickstart</a>
  | <a href="https://www.firezone.dev/kb/client-apps">Download Clients</a>
  | <a href="https://github.com/firezone/firezone/discussions">Discussions</a>
  | <a href="https://www.firezone.dev/support">Support</a>
</p>

---

<p align="center">
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <!--<a href="https://coveralls.io/github/firezone/firezone?branch=main">
    <img src="https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=main" alt="Coverage Status" />
  </a>-->
  <img alt="GitHub commit activity" src="https://img.shields.io/github/commit-activity/m/firezone/firezone"/>
  <img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/firezone/firezone"/>
  <a href="https://x.com/intent/follow?screen_name=firezonehq">
    <img alt="X (formerly Twitter) Follow" src="https://img.shields.io/badge/Follow-%40firezonehq-black?style=flat&logo=x" />
  </a>
</p>

---

## Overview

[Firezone](https://www.firezone.dev/?utm_source=readme) is a secure remote access
platform built on WireGuard®. Connect users to private applications, databases,
servers, and subnets with granular policies that define who can access each
Resource and under what conditions.

Combine identity-based access with cryptographic device verification and detailed
audit records. Gateways run in your infrastructure, and the full product source
is available for inspection in this repository.

<p align="center">
  <img width="570" height="696" alt="Firezone component diagram" src="https://github.com/user-attachments/assets/53bcf629-0e8e-4e37-976d-82f528ad8301" />
</p>

## Getting Started

### Cloud (recommended)

[Sign up free](https://app.firezone.dev/sign_up?utm_source=readme) and follow
the [Quickstart](https://www.firezone.dev/kb/quickstart) to:

1. Deploy a Gateway in the network containing your Resources.
2. Define Resources and policies that grant access to the appropriate groups.
3. Install a Client, sign in, and connect to an authorized Resource.

For plan details and feature availability, see [pricing](https://www.firezone.dev/pricing?utm_source=readme).

### Self-hosting

The [licenses](#license) permit self-hosting, subject to their terms. Production
self-hosting is not officially supported. For development or evaluation, follow
[CONTRIBUTING.md](CONTRIBUTING.md) to run a local environment.

Published Clients are only guaranteed to work with the managed service. Internal
APIs change, and app store releases may lag behind this repository. A self-hosted
portal may require Clients built from a compatible revision. Build instructions
are available in [swift/apple](../swift/apple),
[kotlin/android](../kotlin/android), and [rust/gui-client](../rust/gui-client).

## Features

- **Least-privilege access:** Grant groups access to specific Resources through
  policies, including conditions that require device attestation.
- **Device Trust:** Require cryptographic device verification in addition to user
  authentication, using X.509 certificates issued by your MDM or enterprise PKI.
  [Learn more](https://www.firezone.dev/kb/device-trust).
- **Audit Logs:** Track configuration changes, sessions, API requests, and traffic
  flows with 90-day retention. Export records to your SIEM through Log Sinks.
  [Learn more](https://www.firezone.dev/kb/audit-logs).
- **Device Pools:** Create a peer-to-peer mesh of devices with encrypted
  Client-to-Client WireGuard tunnels, without deploying a Gateway. Policies
  control which groups can reach the devices in each pool.
  [Learn more](https://www.firezone.dev/kb/concepts/resources#device-pools).
- **Identity provider integration:** Authenticate with Google Workspace, Okta,
  Microsoft Entra ID, or OIDC. Directory sync keeps users and groups aligned with
  your identity provider.
- **Encrypted connectivity:** WireGuard tunnels encrypt traffic between Clients
  and Gateways or between devices in a Device Pool. Direct connections reduce
  routing overhead; Relays carry encrypted traffic when a direct connection
  cannot be established.
- **Distributed deployment:** Deploy Gateways near your Resources across cloud
  and on-premises environments. Use multiple Gateways for load balancing and
  failover.
- **Cross-platform access:** Clients are available for Windows, macOS, Linux,
  iOS, and Android, with headless clients for automated workloads.
- **Compliance:** The managed service is SOC 2 Type II compliant.
  See the [Trust Center](https://trust.firezone.dev).

See the [architecture documentation](https://www.firezone.dev/kb/architecture)
for details on the control plane, data plane, and connection lifecycle.

## Performance

- **Throughput:** A typical Gateway on a 4-core Linux host with a recent kernel
  and sub-10ms round-trip latency can deliver 2 Gbps+ of peer-to-peer WireGuard
  traffic. See the [Gateway sizing guidelines](https://www.firezone.dev/kb/deploy/sizing).
- **Latency:** Direct Client-to-Gateway connections avoid a central traffic hub.
  Relays provide connectivity when a direct path is unavailable.
- **Scaling:** Add Gateways to distribute connections and increase aggregate
  capacity. Deploy them near Resources to keep traffic paths short.

Throughput and memory usage depend on hardware, network conditions, and workload.
See the [Gateway sizing documentation](https://www.firezone.dev/kb/deploy/sizing)
for sizing and configuration guidance.

## Repository structure

This monorepo contains the Firezone product:

| Directory                                       | Contents                                        |
| ----------------------------------------------- | ----------------------------------------------- |
| [elixir](../elixir)                             | Admin portal and control plane                  |
| [rust](../rust)                                 | Data plane and shared Rust libraries            |
| [rust/gateway](../rust/gateway)                 | WireGuard tunnel server for your infrastructure |
| [rust/relay](../rust/relay)                     | STUN/TURN relay for connection establishment    |
| [rust/headless-client](../rust/headless-client) | Headless client                                 |
| [rust/gui-client](../rust/gui-client)           | Windows and Linux GUI client                    |
| [swift/apple](../swift/apple)                   | macOS and iOS clients                           |
| [kotlin/android](../kotlin/android)             | Android and ChromeOS clients                    |
| [policy-templates](../policy-templates)         | MDM policy templates for Windows and macOS      |

The marketing website and product documentation live in
[firezone/website](https://github.com/firezone/website).

## Documentation and support

- [Documentation](https://www.firezone.dev/kb): Deployment, configuration, and troubleshooting.
- [GitHub Discussions](https://github.com/firezone/firezone/discussions): Community questions and support.
- [GitHub Issues](https://github.com/firezone/firezone/issues): Bug reports and feature requests.
- [Support](https://www.firezone.dev/support): Support options for your deployment.
- [Contact sales](https://www.firezone.dev/contact/sales?utm_source=readme): Enterprise requirements and deployment planning.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code guidelines,
testing, and the pull request process. Browse
[help wanted issues](https://github.com/firezone/firezone/issues?q=is%3Aissue+is%3Aopen+label%3Akind/help_wanted)
for contribution opportunities.

## Star History

[![Star History Chart](https://api.gitrep.fyi/v1/star-history.svg?repos=firezone/firezone&theme=light&markers=true)](https://gitrep.fyi/history?compare=firezone/firezone)

## Security

To report a vulnerability, follow [SECURITY.md](SECURITY.md). Do not report
security vulnerabilities through public GitHub issues.

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
