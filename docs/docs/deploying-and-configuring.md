---
layout: default
title: Deploying and Configuring
nav_order: 1
---

# Deploying and Configuring
{: .no_toc }


## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---


Firezone consists of a single distributable Linux package that you install and
manage yourself. Management of the Firezone installation is handled by the
`firezone-ctl` utility while management of the VPN and firewall themselves are
handled by the Web UI.

Firezone acts as a frontend to both the WireGuard kernel module and
[netfilter](https://netfilter.org) kernel subsystem. It creates a WireGuard
interface (by default called `wg-firezone`) and
`firezone` netfilter table and adds appropriate routes to the routing
table. Other programs that modify the Linux routing table or netfilter firewall
may interfere with Firezone's operation.

### SSL

Firezone requires a valid SSL certificate and a matching DNS record to run in
production. We recommend using [Let's Encrypt](https://letsencrypt.org) to
generate a free SSL cert for your domain.

### Security Considerations

Firezone is **beta** software. We highly recommend **limiting network access to
the Web UI** (by default port tcp/443) to prevent exposing it to the public Internet.

The WireGuard listen port (by default port udp/51821) should be exposed to allow user
devices to connect.

## Supported Linux Distributions

Firezone currently supports the following distributions and architectures:

| Name | Architectures | Status | Notes |
| --- | --- | --- | --- |
| AmazonLinux 2 | `amd64` | **Fully-supported** | See [AmazonLinux 2 Notes](#amazonlinux-2-notes) |
| CentOS 7 | `amd64` | **Fully-supported** | See [CentOS 7 Notes](#centos-7-notes) |
| CentOS 8 | `amd64` | **Fully-supported** | Works as-is |
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

### Ubuntu 18.04 Notes

Kernel upgrade to 4.19+ required. E.g. `apt install linux-image-generic-hwe-18.04`

### Debian 10 Notes

Kernel upgrade to 4.19+ required. See [this guide
](https://jensd.be/968/linux/install-a-newer-kernel-in-debian-10-buster-stable)
for an example.

### openSUSE Notes

Firezone requires the `setcap` utility, but some recent openSUSE releases may
not have it installed by default. To fix, ensure `libcap-progs` is installed:

```bash
sudo zypper install libcap-progs
```

## Installation Instructions

Assuming you're running Linux kernel 4.19+ on one of the supported distros
listed above, follow these steps to setup and install Firezone:

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

   # ...

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

## Configuration File

User-configurable settings can be found in `/etc/firezone/firezone.rb`.

Changing this file **requires re-running** `sudo firezone-ctl reconfigure` to pick up
the changes and apply them to the running system.