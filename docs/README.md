<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/cae1e42d-78cb-4368-87b0-06b621962233">
    <img alt="Firezone logo" width="400" src="https://github.com/user-attachments/assets/81a90197-2250-4f5c-8195-43e25fb0b0b8">
  </picture>
</p>
<p align="center">
  <strong>Secure remote access with identity-based policies, Device Trust, and Audit Logs.</strong>
</p>

<p align="center">
  <a href="https://www.firezone.dev/kb">Documentation</a>
  | <a href="https://www.firezone.dev/kb/quickstart">Quickstart</a>
  | <a href="https://www.firezone.dev/kb/client-apps">Download Clients</a>
  | <a href="https://github.com/firezone/firezone/discussions">Discussions</a>
  | <a href="https://www.firezone.dev/support">Support</a>
</p>

## Overview

[Firezone](https://www.firezone.dev/?utm_source=readme) is a secure remote access
platform built on WireGuard®. Connect users to private applications, databases,
servers, and subnets with granular policies that define who can access each
Resource and under what conditions.

Combine identity-based access with cryptographic device verification and detailed
audit records. Gateways run in your infrastructure, and the full product source
is available for inspection in this repository.

<p align="center">
  <img width="516" height="630" alt="Firezone component diagram" src="https://github.com/user-attachments/assets/4907c733-168d-41c5-a6a0-fd020483bc96" />
</p>

## Security and access controls

- **Least-privilege access:** Grant groups access to specific Resources through
  policies, including conditions that require device attestation.
- **Identity provider integration:** Authenticate with Google Workspace, Okta,
  Microsoft Entra ID, or OIDC. Directory sync keeps users and groups aligned with
  your identity provider.
- **Encrypted connectivity:** WireGuard tunnels encrypt traffic between Clients
  and Gateways. Direct connections reduce routing overhead; Relays carry
  encrypted traffic when a direct connection cannot be established.
- **Distributed deployment:** Deploy Gateways near your Resources across cloud
  and on-premises environments. Use multiple Gateways for load balancing and
  failover.
- **Cross-platform access:** Clients are available for Windows, macOS, Linux,
  iOS, and Android, with headless clients for automated workloads.

See the [architecture documentation](https://www.firezone.dev/kb/architecture)
for details on the control plane, data plane, and connection lifecycle.

### Device Trust

Require a verified device identity in addition to user authentication before
allowing access to sensitive Resources. Device Trust validates X.509 certificates
issued by your MDM or enterprise PKI and requires the Client to prove possession
of the corresponding private key.

Apply the **Require attestation** policy condition to restrict access to devices
with a trusted certificate. Device keys can be hardware-backed where supported.
Device Trust verifies device identity; it does not evaluate OS version, disk
encryption, or endpoint protection status.

[Learn about Device Trust](https://www.firezone.dev/kb/device-trust) or follow the
[setup guide](https://www.firezone.dev/kb/device-trust/setup).

### Audit Logs

Investigate access, review configuration changes, and support compliance reviews
with four audit log streams:

| Log stream       | Visibility                                       |
| ---------------- | ------------------------------------------------ |
| Change Logs      | Who changed account configuration and when       |
| Session Logs     | Who connected, from where, and with which device |
| API Request Logs | Requests made using API tokens                   |
| Flow Logs        | Traffic between Clients and Resources            |

Logs are retained for 90 days and can be reviewed in the admin portal or queried
through the REST API. Stream records to your SIEM or log management platform with
Log Sinks.

[Learn about Audit Logs](https://www.firezone.dev/kb/audit-logs) and
[configure Log Sinks](https://www.firezone.dev/kb/log-sinks).

## Getting started

[Create an account](https://app.firezone.dev/sign_up?utm_source=readme) and follow
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
