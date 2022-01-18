---
layout: default
title: Install
nav_order: 2
parent: Get Started
---

# Install
{: .no_toc }
---

**Important**: Ensure you've satisfied the [prerequisites]({{ site.baseurl }}{% link docs/get-started/prerequisites.md %})
before following this guide.

## Table of Contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Supported Linux Distributions

Firezone currently supports the following distributions and architectures:

| Name | Architectures | Status | Notes |
| --- | --- | --- | --- |
| AmazonLinux 2 | `amd64` | **Fully-supported** | See [AmazonLinux 2 Notes](#amazonlinux-2-notes) |
| CentOS 7 | `amd64` | **Fully-supported** | See [CentOS 7 Notes](#centos-7-notes) |
| CentOS 8 | `amd64` | **Fully-supported** | See [CentOS 8 Notes](#centos-8-notes) |
| Debian 10 | `amd64` | **Fully-supported** | See [Debian 10 Notes](#debian-10-notes)|
| Debian 11 | `amd64` | **Fully-supported** | Works as-is |
| Fedora 33 | `amd64` | **Fully-supported** | Works as-is |
| Fedora 34 | `amd64` | **Fully-supported** | Works as-is |
| Ubuntu 18.04 | `amd64` | **Fully-supported** | See [Ubuntu 18.04 Notes](#ubuntu-1804-notes) |
| Ubuntu 20.04 | `amd64` | **Fully-supported** | Works as-is |
| openSUSE Leap 15.3 | `amd64` | **Fully-supported** | See [openSUSE Notes](#opensuse-notes) |

If your distro isn't listed here please
[open an issue](https://github.com/firezone/firezone/issues/new/choose) and let
us know. New distros are being supported on a regular basis and there's a good
chance yours will be added soon.

### AmazonLinux 2 Notes

Kernel upgrade required:

```bash
sudo amazon-linux-extras install -y kernel-5.10
```

### CentOS 7 Notes

Kernel upgrade to 4.19+ required. See [this guide
](https://medium.com/@nazishalam07/update-centos-kernel-3-10-to-5-13-latest-9462b4f1e62c)
for an example.

### CentOS 8 Notes

The WireGuard kernel module needs to be installed:

```bash
yum install elrepo-release epel-release
yum install kmod-wireguard
```

### Ubuntu 18.04 Notes

Kernel upgrade to 4.19+ required. E.g. `apt install linux-image-generic-hwe-18.04`

### Debian 10 Notes

Kernel upgrade to 5.6+ required. See [this guide
](https://jensd.be/968/linux/install-a-newer-kernel-in-debian-10-buster-stable)
for an example.

### openSUSE Notes

Firezone requires the `setcap` utility, but some recent openSUSE releases may
not have it installed by default. To fix, ensure `libcap-progs` is installed:

```shell
sudo zypper install libcap-progs
```

## Installation Instructions

**NOTE**: Firezone modifies the kernel netfilter and routing tables. Other
programs that modify the Linux routing table or netfilter firewall
will likely interfere with Firezone's operation.

Assuming you're running Linux kernel 4.19+ on one of the supported distros
listed above, follow these steps to install and configure Firezone for first
use:

1. [Install WireGuard](https://www.wireguard.com/install/) for your distro. If using Linux kernel 5.6 or higher, skip
   this step.
2. Download the relevant package for your distribution from the
   [releases page](https://github.com/firezone/firezone/releases).
3. Install with `sudo rpm -i firezone*.rpm` or `sudo dpkg -i firezone*.deb`
   depending on your distro.
4. Bootstrap the application with `sudo firezone-ctl reconfigure`. This will initialize config files, set up needed services and generate the default configuration.
5. Edit the default configuration located at `/etc/firezone/firezone.rb`.
   At a minimum, you'll need to review the following configuration variables:

   ```ruby
   # Auto-generated based on the server's hostname.
   # Set this to the FQDN used to access the Web UI.
   default['firezone']['fqdn'] = 'firezone.example.com'

   # Specify the path to your SSL cert and private key.
   # If set to nil, a self-signed cert will be generated for you.
   default['firezone']['ssl']['certificate'] = '/path/to/cert.pem'
   default['firezone']['ssl']['certificate_key'] = '/path/to/key.pem'
   ```
6. Reconfigure the application to pick up the new changes: `sudo firezone-ctl reconfigure`.
7. Finally, create an admin user with `sudo firezone-ctl create-or-reset-admin`.
   The login credentials will be printed to the console output.
8. Now you should be able to log into the web UI at the FQDN you specified in
   step 5 above, e.g. `https://firezone.example.com`

Next, proceed to [read about using Firezone]({{ site.baseurl }}{% link docs/usage/index.md %}).
