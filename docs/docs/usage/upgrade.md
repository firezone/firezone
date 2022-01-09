---
layout: default
title: Upgrade
nav_order: 2
parent: Usage
---

# Upgrade

---

Upgrading Firezone will disconnect all VPN connections and require shutting
down the Web UI. We recommend a maintenance window of about an hour in case
anything goes wrong during the upgrade.

To upgrade Firezone, simply download the new OS package, install it over the existing installation with `sudo dpkg -i firezone_X.X.X.deb` or
`sudo rpm -i firezone_X.X.X.rpm` and then run `sudo firezone-ctl reconfigure`.

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
