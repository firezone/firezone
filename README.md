![](./apps/fz_http/assets/static/images/logo.svg)

![Test](https://github.com/firezone/firezone/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=master)](https://coveralls.io/github/FireZone-LLC/firezone?branch=master)

![IMG_0023](https://user-images.githubusercontent.com/167144/132162016-c17635ae-a715-41ca-b6f9-7cbdf202f8d5.png)

# FireZone

1. [Intro](#intro)
2. [Requirements](#requirements)
3. [Install](#install)
4. [Usage](#usage)
5. [Architecture](#architecture)
6. [Contributing](#contributing)

## Intro

`firezone` is an open-source WireGuard™-based VPN server and firewall for Linux
designed to be secure and simple to set up and manage.

Use FireZone to:

- Connect remote teams to a shared private cloud network
- Set up your own WireGuard™ VPN
- Block egress traffic from your devices to specific IPs and CIDR ranges
- Connect remote teams to a secure virtual LAN

## Requirements

FireZone currently supports the following Linux distros:

- CentOS: `7`, `8`
- Ubuntu: `18.04`, `20.04`
- Debian: `10`, `11`
- Fedora: `33`, `34`

If your distro isn't listed here please [open an issue](https://github.com/firezone/firezone/issues/new/choose) and we'll look into adding it.

FireZone requires a valid SSL certificate and a matching DNS record to run in production.

## Install

1. Download the relevant package for your distribution from the [releases page](https://github.com/firezone/firezone/releases)
2. Install with `sudo rpm -i firezone-<version>.rpm` or `sudo dpkg -i firezone-<version>.deb` depending on your distribution. This will unpack the application and set up necessary directory structure.
3. Bootstrap the application with `sudo firezone-ctl reconfigure`. This will initialize config files, set up needed services and generate the default configuration.
4. Edit the default configuration at `/etc/firezone/firezone.rb`. You'll want to make sure `default['firezone']['fqdn']`, `default['firezone']['url_host']`, `default['firezone']['ssl']['certificate']`, and `default['firezone']['ssl']['certificate']` are set properly.
5. Reconfigure the application to pick up the new changes: `sudo firezone-ctl reconfigure`.
6. Finally, create an admin user with `sudo firezone-ctl create_admin`. Check the console for the login credentials.
7. Now you should be able to log into the web UI at `https://<your-server-fqdn>`


## Architecture

`firezone` is written in the Elixir programming language and composed as an [Umbrella
project](https://elixir-lang.org/getting-started/mix-otp/dependencies-and-umbrella-projects.html)
consisting of three independent applications:

- [apps/fz_http](apps/fz_http): The Web Application
- [apps/fz_wall](apps/fz_wall): Firewall Management Process
- [apps/fz_vpn](apps/fz_vpn): WireGuard™ Management Process

For now, `firezone` assumes these apps are all running on the same host.

[Chef Omnibus](https://github.com/chef/omnibus) is used to bundle all FireZone dependencies into a single distributable Linux package.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

WireGuard™ is a registered trademark of Jason A. Donenfeld.
