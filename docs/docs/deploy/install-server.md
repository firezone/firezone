---
title: Install Server
sidebar_position: 3
---

**Important**: Ensure you've satisfied the
[prerequisites](../deploy/prerequisites) before following this
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

This will ask you a few questions regarding your install, install the latest
release for your platform, then create an administrator user and print to the
console instructions for logging in to the web UI.

If that fails, try the manual installation method below.

### Manual Install

If the Automatic Install fails, try these steps to install Firezone manually.

1. [Install WireGuard](https://www.wireguard.com/install/) for your distro.
   If using Linux kernel 5.6 or higher, skip this step.

1. Install our package [repository](https://cloudsmith.io/~firezone/repos/firezone)
    for your distro's package format:
    - deb packages:

        ```bash
        curl -1sLf \
          'https://dl.cloudsmith.io/public/firezone/firezone/setup.deb.sh' \
          | sudo -E bash
        ```

    - rpm packages:

        ```bash
        curl -1sLf \
          'https://dl.cloudsmith.io/public/firezone/firezone/setup.rpm.sh' \
          | sudo -E bash
        ```

    See Cloudsmith [setup docs](https://cloudsmith.io/~firezone/repos/firezone/setup)
    for more info.

1. Install Firezone with your distro's package manager:

    ```bash
    # Using apt
    sudo apt install firezone

    # Using dnf
    sudo dnf install firezone

    # Using yum
    sudo yum install firezone

    # Using zypper
    sudo zypper install firezone
    ```

1. Bootstrap the application with `sudo firezone-ctl reconfigure`. This will
   initialize config files, set up needed services and generate the default
   configuration.
1. Edit the default configuration located at `/etc/firezone/firezone.rb`.
   We've chosen sensible defaults that should be a good starting point for most
   installations. For production installations, you'll want to specify a valid
   external URL and enable ACME for certificate issuance and renewal:

   ```ruby
   # Auto-generated based on the server's hostname.
   # Set this to the URL used to access the Firezone Web UI.
   default['firezone']['external_url'] = 'https://firezone.example.com'

   # Set the email that will be used for the issued certificates and certifications.
   default['firezone']['ssl']['email_address'] = 'your@email.com'

   # Enable ACME renewal
   default['firezone']['ssl']['acme']['enabled'] = true
   ```

   See the complete [configuration file reference for more details](../reference/configuration-file).

1. Reconfigure the application to pick up the new changes:
   `sudo firezone-ctl reconfigure`.
1. Finally, create an admin user with `sudo firezone-ctl create-or-reset-admin`.
   The login credentials will be printed to the console output.
1. Now you should be able to sign in to the web UI at the URL you specified in
   step 5 above, e.g. `https://firezone.example.com`

Find solutions to common issues during deployment in [Troubleshoot](../administer/troubleshoot).
