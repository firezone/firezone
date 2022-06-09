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

To upgrade Firezone, follow these steps:

1. Download the new release for your platform.
1. Install the new package over the old one:
  `sudo dpkg -i firezone_X.X.X.deb` or
  `sudo rpm -i --force firezone_X.X.X.rpm` depending on your distribution.
1. Run `firezone-ctl reconfigure` to pick up the new changes.
1. Run `firezone-ctl restart` to restart services.

Occasionally problems arise. If you hit any, please let us know by [filing an
issue](https://github.com/firezone/firezone/issues/new/choose).

## Upgrading from 0.3.x to >= 0.4.0

**Important**: Before upgrading to `0.4.0`, we highly recommend first upgrading
to the latest point-release of the `0.3.x` series (`0.3.17` at the time of this
writing). This will ensure your instance and data is in a consistent state
for the 0.4.0 migration script to execute smoothly.

**Important**: Upgrading from 0.3.x to >= 0.4.0 involves running a large
database migration. We highly recommend accounting for some downtime (1-2 hours)
to perform this upgrade to give the migrations time to complete, especially
if you have lots of devices and users.

Firezone 0.4.0 adds the ability to manage multiple WireGuard networks in a
single instance. As such, the following config options have been moved to the
fields of the `networks` table:

```
default['firezone']['wireguard']['interface_name']
default['firezone']['wireguard']['port']
default['firezone']['wireguard']['mtu']
default['firezone']['wireguard']['endpoint']
default['firezone']['wireguard']['dns']
default['firezone']['wireguard']['allowed_ips']
default['firezone']['wireguard']['persistent_keepalive']
default['firezone']['wireguard']['ipv4']['enabled']
default['firezone']['wireguard']['ipv4']['network']
default['firezone']['wireguard']['ipv4']['address']
default['firezone']['wireguard']['ipv6']['enabled']
default['firezone']['wireguard']['ipv6']['network']
default['firezone']['wireguard']['ipv6']['address']
```

In the 0.4.0 migration script, these configuration variables will be used to
bootstrap the first network record. If any are missing, defaults are used
instead. If you'd like to customize the initial network beyond the defaults
shown in the configuration file, we recommend configuring them here and doing
a `firezone-ctl reconfigure` **before** upgrading to `0.4.0`.

For any questions or issues, please don't hesitate to [join our Slack for help](
https://firezone.dev/slack)


## Upgrading from 0.3.1 to >= 0.3.2

The configuration option `default['firezone']['fqdn']` has been removed in favor
of `default['firezone']['external_url']`. Please set this to the
publicly-accessible URL of your Firezone web portal. If left unspecified it will
default to `https://` + the FQDN of your server.

Reminder, the configuration file can be found at `/etc/firezone/firezone.rb`.
For an exhaustive list of configuration variables and their descriptions, see the
[configuration file reference]({%link docs/reference/configuration-file.md%}).

## Upgrading from 0.2.x to 0.3.x

**Note**: Starting with version 0.3.0, Firezone no longer stores device private
keys on the Firezone server. Any existing devices should continue to function
as-is, but you will not be able to re-download or view these configurations in
the Firezone Web UI.

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
