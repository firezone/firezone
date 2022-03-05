---
layout: default
title: Upgrade
nav_order: 3
parent: Administer
description: >
  To upgrade Firezone, download the release package and run these commands.
  We recommend keeping your Firezone installation up-to-date.
---
---

Upgrading Firezone will disconnect all VPN sessions and require shutting
down the Web UI. We recommend a maintenance window of about an hour in case
anything goes wrong during the upgrade.

We're actively working on making this process more automatic in the future, but
for now, this is the procedure for upgrading your Firezone instance.

To upgrade Firezone, follow these steps:

1. Download the new release for your platform.
1. Install the new package over the old one:
  `sudo dpkg -i firezone_X.X.X.deb` or
  `sudo rpm -i --force firezone_X.X.X.rpm` depending on your distribution.
1. Run `firezone-ctl reconfigure` to pick up the new changes.
1. Run `firezone-ctl restart` to restart services.

Occasionally problems arise. If you hit any, please let us know by [filing an
issue](https://github.com/firezone/firezone/issues/new/choose).

## Upgrading from 0.1.x to 0.2.x

Firezone 0.2.x contains some configuration file changes that will need to be
handled manually if you're upgrading from 0.1.x. Run the commands below as root
to perform the needed changes to your `/etc/firezone/firezone.rb` file.

```bash
cp /etc/firezone/firezone.rb /etc/firezone/firezone.rb.bak
sed -i "s/\['enable'\]/\['enabled'\]/" /etc/firezone/firezone.rb
echo "default['firezone']['connectivity_checks']['enabled'] = true" >> /etc/firezone/firezone.rb
echo "default['firezone']['connectivity_checks']['interval'] = 3_600" >> /etc/firezone/firezone.rb
firezone-ctl reconfigure
firezone-ctl restart
```
