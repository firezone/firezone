![](./apps/fz_http/assets/static/logo.svg)

![Test](https://github.com/firezone/firezone/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/firezone/firezone/badge.svg?branch=master)](https://coveralls.io/github/FireZone-LLC/firezone?branch=master)

**Warning**: This project is under active development and is not secure at the moment.
Do not attempt to use this software in any production capacity until this notice is removed.

You have been warned.

# FireZone

1. [Intro](#intro)
2. [Architecture](#architecture)
3. [Install](#install)
4. [Usage](#usage)
5. [Contributing](#contributing)

## Intro

`firezone` is an open-source WireGuard™ VPN and firewall manager for Linux
designed to be easy-to-use, secure, and useful for individuals and small teams.

Use `firezone` to:

- Connect remote teams in a secure virtual LAN
- Set up your own WireGuard™ VPN
- Block egress traffic to specific IPs and CIDR ranges
- Configure DNS in one central place for all your devices

## Architecture

`firezone` is written in the Elixir programming language and composed as an [Umbrella
project](https://elixir-lang.org/getting-started/mix-otp/dependencies-and-umbrella-projects.html)
consisting of three independent applications:

- [apps/fz_http](apps/fz_http): The Web Application
- [apps/fz_wall](apps/fz_wall): Firewall Management Process
- [apps/fz_vpn](apps/fz_vpn): WireGuard™ Management Process

For now, `firezone` assumes these apps are all running on the same host.

## Install

Prerequisites:

1. Postgresql Server 9.6 or higher. Access can be configured in
   `/etc/firezone/secret/secrets.env` after installation.
2. `wg`, `openssl`, `ip`, and `iptables` must be in your PATH.

Then you can install `firezone` by [downloading the appropriate package
from the releases page](https://github.com/firezone/firezone/releases).

## Creating additional admin users

You may create additional admin users with the following command:

```bash
> firezone rpc 'FzHttp.Users.create_user(
  email: "USER_EMAIL",
  password: "USER_PASSWORD",
  password_confirmation: "USER_PASSWORD"
)'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

WireGuard™ is a registered trademark of Jason A. Donenfeld.
