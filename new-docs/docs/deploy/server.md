---
layout: default
title: Install Server
nav_order: 4
parent: Deploy
description: >
  To install Firezone on your server, follow these steps.
---

**Important**: Ensure you've satisfied the
[prerequisites]({% link docs/deploy/prerequisites.md %}) before following this
guide.

## Installation Instructions

Assuming you're running a supported Linux kernel on one of the [supported
platforms](#supported-linux-distributions), use one of the methods below
to get started:

- [Installation Instructions](#installation-instructions)
  - [Automatic Install](#automatic-install)
  - [Manual Install](#manual-install)

### Automatic Install

The easiest way to get started using Firezone is via the automatic installation
script:

```bash
bash <(curl -Ls https://github.com/firezone/firezone/raw/master/scripts/install.sh)
```

This will ask you a few questions regarding your install, download the latest
release for your platform, then create an administrator user and print to the
console instructions for logging in to the web UI.

If that fails, try the manual installation method below.

### Manual Install

If the Automatic Install fails, try these steps to install Firezone manually.

1. [Install WireGuard](https://www.wireguard.com/install/) for your distro.
   If using Linux kernel 5.6 or higher, skip this step.
1. Download the relevant package for your distribution from the
   [releases page](https://github.com/firezone/firezone/releases).
1. Install with `sudo rpm -i firezone*.rpm` or `sudo dpkg -i firezone*.deb`
   depending on your distro.
1. Bootstrap the application with `sudo firezone-ctl reconfigure`. This will
   initialize config files, set up needed services and generate the default
   configuration.
1. Edit the default configuration located at `/etc/firezone/firezone.rb`.
   We've chosen sensible defaults that should be a good starting point for most
   installations. For production installations, you'll want to specify your
   FQDN and SSL certificate paths:

   ```ruby
   # Auto-generated based on the server's hostname.
   # Set this to the URL used to access the Firezone Web UI.
   default['firezone']['external_url'] = 'https://firezone.example.com'

   # Specify the path to your SSL cert and private key.
   # If set to nil (default), a self-signed cert will be generated for you.
   default['firezone']['ssl']['certificate'] = '/path/to/cert.pem'
   default['firezone']['ssl']['certificate_key'] = '/path/to/key.pem'
   ```

   See the complete [configuration file reference for more details](../reference/configuration-file).

1. Reconfigure the application to pick up the new changes:
   `sudo firezone-ctl reconfigure`.
1. Finally, create an admin user with `sudo firezone-ctl create-or-reset-admin`.
   The login credentials will be printed to the console output.
1. Now you should be able to sign in to the web UI at the URL you specified in
   step 5 above, e.g. `https://firezone.example.com`

Find solutions to common issues during deployment in [Troubleshoot](../administer/troubleshoot).
