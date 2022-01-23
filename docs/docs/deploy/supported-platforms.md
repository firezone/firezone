---
layout: default
title: Supported Platforms
nav_order: 0
parent: Deploy
---
---

Firezone currently supports the following platforms:

<!-- markdownlint-disable MD013 -->

| OS | Architectures | Status | Notes |
| --- | --- | --- | --- |
| AmazonLinux 2 | `amd64` | **Fully-supported** | See [AmazonLinux 2 Notes](#amazonlinux-2-notes) |
| CentOS 7 | `amd64` | **Fully-supported** | See [CentOS 7 Notes](#centos-7-notes) |
| CentOS 8 | `amd64` | **Fully-supported** | See [CentOS 8 Notes](#centos-8-notes) |
| CentOS Stream 9 | `amd64` | **Fully-supported** | Works as-is |
| Debian 10 | `amd64` | **Fully-supported** | See [Debian 10 Notes](#debian-10-notes)|
| Debian 11 | `amd64` | **Fully-supported** | Works as-is |
| Fedora 33 | `amd64` | **Fully-supported** | Works as-is |
| Fedora 34 | `amd64` | **Fully-supported** | Works as-is |
| Fedora 35 | `amd64` | **Fully-supported** | Works as-is |
| Ubuntu 18.04 | `amd64` | **Fully-supported** | See [Ubuntu 18.04 Notes](#ubuntu-1804-notes) |
| Ubuntu 20.04 | `amd64` | **Fully-supported** | Works as-is |
| openSUSE Leap 15.3 | `amd64` | **Fully-supported** | See [openSUSE Notes](#opensuse-notes) |

<!-- markdownlint-enable MD013 -->

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

Kernel upgrade to 5.6+ required. See [this guide
](https://medium.com/@nazishalam07/update-centos-kernel-3-10-to-5-13-latest-9462b4f1e62c)
for an example.

### CentOS 8 Notes

The WireGuard kernel module needs to be installed:

```bash
yum install elrepo-release epel-release
yum install kmod-wireguard
```

### Ubuntu 18.04 Notes

Kernel upgrade to 5.4+ required. E.g. `apt install linux-image-generic-hwe-18.04`

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
