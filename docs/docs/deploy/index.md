---
layout: default
title: Deploy
nav_order: 2
has_children: true
has_toc: false
description: >
  Get started with Firezone in a few minutes by self-hosting on a supported platform.
  This section walks through the steps to deploy Firezone.
---

### Get started with Firezone in a few minutes by self-hosting on a supported platform

---

Firezone can be self-hosted on a server running a supported
[Linux distribution]({% link docs/deploy/supported-platforms.md %})
in a few minutes. This guide will walk you through the steps to get started.

## Step 1: Environment Setup

### Supported operating systems

Start by checking if your environment is listed on
[supported platforms]({% link docs/deploy/supported-platforms.md %}).
A kernel upgrade may be required to ensure WireGuard® is available.

### Security settings

Ensure port forwarding is enabled on your firewall.
The default Firezone configuration requires the following ports to be open:

* `443/tcp`: To access the web UI.
* `51820/udp`: The VPN traffic listen-port.

**Note**: Firezone modifies the kernel netfilter and routing tables.
Other programs that modify the Linux routing table or firewall may interfere
with Firezone’s operation. For help troubleshooting connectivity issues, see the
[troubleshooting guide]({% link docs/administer/troubleshoot.md %}).

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

![install complete](https://user-images.githubusercontent.com/52545545/171948328-4771552f-e5dd-4c30-8c0b-baac80b6e7b1.png){:width="600"}

**Note**: During install new firewall rules are added, which can interrupt the
SSH connection. If this happens and you miss the admin
instructions, reconnect to the
server to run `firezone-ctl create-or-reset-admin`.
This will re-create the admin user and output the address of the web UI to the console.
We are actively working on a fix for this [issue](https://github.com/firezone/firezone/issues/478).

By default, the web UI can be reached at the IP or domain name of your server.
You can regenerate the admin credentials using the
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

First, check our
[troubleshooting guide]({% link docs/administer/troubleshoot.md %})
to see if your issue is covered there.
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
