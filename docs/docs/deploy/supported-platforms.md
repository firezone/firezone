---
layout: default
title: Supported Platforms
nav_order: 1
parent: Deploy
description: >
  This section describes the supported platforms for Firezone. For
  some platforms a kernel upgrade may be required to ensure WireGuard® is
  available.
---

Firezone currently supports the following platforms:

<!-- markdownlint-disable MD013 -->

| OS | Architectures | Status | Notes |
| --- | --- | --- | --- |
| AmazonLinux 2 | `amd64` `arm64` | **Fully-supported** | See [AmazonLinux 2 Notes](#amazonlinux-2-notes) |
| CentOS 7 | `amd64` | **Fully-supported** | See [CentOS 7 Notes](#centos-7-notes) |
| CentOS 8 | `amd64` `arm64` | **Fully-supported** | See [CentOS 8 Notes](#centos-8-notes) |
| CentOS Stream 9 | `amd64` `arm64` | **Fully-supported** | Works as-is |
| Red Hat Enterprise Linux 7 | `amd64` | **Fully-supported** | See [RHEL 7 Notes](#rhel-7-notes) |
| Red Hat Enterprise Linux 8 | `amd64` `arm64` | **Fully-supported** | See [RHEL 8 Notes](#rhel-8-notes) |
| Red Hat Enterprise Linux 9 | `amd64` `arm64` | **Fully-supported** | See [RHEL 9 Notes](#rhel-9-notes) |
| Debian 10 | `amd64` `arm64` | **Fully-supported** | See [Debian 10 Notes](#debian-10-notes)|
| Debian 11 | `amd64` `arm64` | **Fully-supported** | Works as-is |
| Fedora 33 | `amd64` `arm64` | **Fully-supported** | See [Fedora Notes](#fedora-notes) |
| Fedora 34 | `amd64` `arm64` | **Fully-supported** | See [Fedora Notes](#fedora-notes) |
| Fedora 35 | `amd64` `arm64` | **Fully-supported** | See [Fedora Notes](#fedora-notes) |
| Ubuntu 18.04 | `amd64` `arm64` | **Fully-supported** | See [Ubuntu 18.04 Notes](#ubuntu-1804-notes) |
| Ubuntu 20.04 | `amd64` `arm64` | **Fully-supported** | Works as-is |
| openSUSE Leap 15.3 | `amd64` | **Fully-supported** | See [openSUSE Notes](#opensuse-notes) |

<!-- markdownlint-enable MD013 -->

If your distro isn't listed here  please try using a package for the closest
distro first. For example, since Raspberry Pi OS is based on Debian, try using
the Debian Firezone package.

If that doesn't work, please
[open an issue](https://github.com/firezone/firezone/issues/new/choose)
and let us know. New distros are being supported on a regular basis and there's
a good chance yours will be added soon.

Note that we only support RPM and DEB based packaging systems. Others, like Arch
Linux are currently being investigated [
in this issue](https://github.com/firezone/firezone/issues/378).

## AmazonLinux 2 Notes

Kernel upgrade required:

```shell
sudo amazon-linux-extras install -y kernel-5.10
```

## CentOS 7 Notes

Kernel upgrade to 5.6+ required. To upgrade to the latest mainline kernel and
select it as the default boot kernel:

```shell
sudo rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
sudo yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
sudo yum install -y elrepo-release
sudo yum --enablerepo=elrepo-kernel install -y kernel-ml
sudo grub2-set-default 0
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

## CentOS 8 Notes

The WireGuard kernel module needs to be installed:

```shell
yum install elrepo-release epel-release
yum install kmod-wireguard
```

## RHEL 7 Notes

Red Hat Enterprise Linux is binary compatible with CentOS, so the Firezone
package for CentOS 7 should work just fine for RHEL 7. You'll still need to
upgrade your kernel to 5.6+ however. To do so, follow the steps for
[CentOS 7 Notes](#centos-7-notes) above.

## RHEL 8 Notes

Red Hat Enterprise Linux is binary compatible with CentOS, so the Firezone
package for CentOS 8 should work just fine for RHEL 8. You'll still need to
install the WireGuard kernel module, however. See [CentOS 8 Notes
](#centos-8-notes) above.

## RHEL 9 Notes

Use the package for CentOS 9.

## Fedora Notes

On fresh Fedora installations you'll probably need to install a cron
implementation to support the logrotate functionality, otherwise
you may receive errors about a missing `/etc/cron.hourly` directory.

```shell
yum install cronie-anacron
```

## Ubuntu 18.04 Notes

Kernel upgrade to 5.4+ required:

```shell
sudo apt install linux-image-generic-hwe-18.04
```

## Debian 10 Notes

Kernel upgrade to 5.6+ required. See [this guide
](https://jensd.be/968/linux/install-a-newer-kernel-in-debian-10-buster-stable)
for an example.

## openSUSE Notes

Firezone requires the `setcap` utility, but some recent openSUSE releases may
not have it installed by default. To fix, ensure `libcap-progs` is installed:

```shell
sudo zypper install libcap-progs
```
