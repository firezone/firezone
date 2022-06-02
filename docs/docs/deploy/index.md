---
layout: default
title: Deploy
nav_order: 2
has_children: true
has_toc: false
description: >
  This section walks through the steps to deploy Firezone.
---
---

Firezone can be self-hosted on a server running a supported
[Linux distribution]({% link docs/deploy/supported-platforms.md %})
in a few minutes. This guide will walk you through the steps to get started.

## Step 1: Environment Setup

### Supported operating systems

Start by checking if your environment is listed on
[supported platforms]({% link docs/deploy/supported-platforms.md %}).
A kernel upgrade may be required to ensure WireGuard® is available.

### Firewall settings

Firezone requires ports `80/tcp`, `443/tcp`, and `51820/udp` to be open.

### Production deployments

Firezone requires the setup of a DNS record and matching SSL certificate
for production deployments. See instructions
[here]({% link docs/deploy/prerequisites.md %}).

## Step 2: Server Install Script

The easiest way to get started using Firezone is via the automatic installation
script below.

```bash
bash <(curl -Ls https://github.com/firezone/firezone/raw/master/scripts/install.sh)
```

This will ask you a few questions regarding your install, download the latest
release for your platform, then create an administrator user and print to the
console instructions for logging in to the web UI.

By default, the web UI can be reached at the IP or domain name of your server.
You can re-generate the admin credentials using the
`firezone-ctl create-or-reset-admin` command.

If the script fails, follow instructions for
[manual installation]({% link docs/deploy/server.md %}).

## Step 3: Install Client Apps

Once successfully deployed, users and devices can be added to
connect to the VPN server:

* [Add Users]({%link docs/user-guides/add-users.md%}):
Add users to grant them access to your network.
* [Client Instructions]({%link docs/user-guides/client-instructions.md%}):
Instructions to establish a VPN session.

## Troubleshooting

Check the [troubleshooting guide]({% link docs/administer/troubleshoot.md %}).
If you are unable to resolve the issue:

* Ask a question in our
[discussion forums](https://discourse.firez.one/) or
[Slack channel](https://www.firezone.dev/slack)
* Report bugs or propose new features on
[Github](https://github.com/firezone/firezone)

## After Setup

Congrats! You have completed the setup, but there's a lot more you can do with Firezone.

* [Integrate your identity provider]({% link docs/authenticate/index.md %})
for authenticating clients
* Using Firezone to
[establish a static IP]({% link docs/user-guides/whitelist-vpn.md %})
* Create tunnels between multiple peers with
[reverse tunnels]({% link docs/user-guides/reverse-tunnel.md %})
* Only route certain traffic through Firezone with
[split tunneling]({% link docs/user-guides/split-tunnel.md %})

Support us by:

* Star our repo on [Github](https://github.com/firezone/firezone)
* Follow us on Twitter at [@firezonehq](https://twitter.com/firezonehq)
* Follow us on LinkedIn at [@firezonehq](https://www.linkedin.com/company/firezonehq)
