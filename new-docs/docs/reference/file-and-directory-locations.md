---
layout: default
nav_order: 3
title: File and Directory Locations
parent: Reference
description: >
  Locations of various files and directories related to
  a typical Firezone installation.
---

Here you'll find a listing of files and directories related to a typical
Firezone installation. These could change depending on changes to your
configuration file.

<!-- markdownlint-disable MD013 -->

| path | description |
| --- | --- |
| `/var/opt/firezone` | Top-level directory containing data and generated configuration for Firezone bundled services. |
| `/opt/firezone` | Top-level directory containing built libraries, binaries and runtime files needed by Firezone. |
| `/usr/bin/firezone-ctl` | `firezone-ctl` utility for managing your Firezone installation. |
| `/etc/systemd/system/firezone-runsvdir-start.service` | systemd unit file for starting the Firezone runsvdir supervisor process. |
| `/etc/firezone` | Firezone configuration files. |

<!-- markdownlint-disable MD013 -->
