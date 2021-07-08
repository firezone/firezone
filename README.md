![](./apps/cf_http/assets/static/logo.svg)

![Test](https://github.com/CloudFire-LLC/cloudfire/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/CloudFire-LLC/cloudfire/badge.svg?branch=master)](https://coveralls.io/github/CloudFire-LLC/cloudfire?branch=master)

**Warning**: This project is under active development and is not secure at the moment.
Do not attempt to use this software in any production capacity until this notice is removed.

You have been warned.

# CloudFire

1. [Intro](#intro)
2. [Architecture](#architecture)
3. [Install](#install)
4. [Usage](#usage)
5. [Contributing](#contributing)

## Intro

`cloudfire` is an open-source WireGuard™ VPN and firewall manager for Linux
designed to be easy-to-use, secure, and useful for individuals and small teams.

Use `cloudfire` to:

- Connect remote teams in a secure virtual LAN
- Set up your own WireGuard™ VPN
- Block egress traffic to specific IPs and CIDR ranges
- Configure DNS in one central place for all your devices

## Architecture

`cloudfire` is written in the Elixir programming language and composed as an [Umbrella
project](https://elixir-lang.org/getting-started/mix-otp/dependencies-and-umbrella-projects.html)
consisting of three independent applications:

- [apps/cf_http](apps/cf_http): The Web Application
- [apps/cf_wall](apps/cf_wall): Firewall Management Process
- [apps/cf_vpn](apps/cf_vpn): WireGuard™ Management Process

For now, `cloudfire` assumes these apps are all running on the same host.

## Install

Prerequisites:

1. Postgresql Server 9.6 or higher. Access can be configured in
   `~/.cloudfire/config.json` after installation.
2. `wg`, `openssl`, `ip`, and `iptables` must be in your PATH.

Then you can install `cloudfire` with:

`curl https://raw.githubusercontent.com/CloudFire-LLC/cloudfire/master/scripts/install.sh | bash -`

This will download the `cloudfire` binary, initialize the config directory, and
print further instructions to the console.

## Creating additional admin users

You may create additional admin users with the following command:

```bash
cloudfire rpc 'CfHttp.Users.create_user(
  email: "USER_EMAIL",
  password: "USER_PASSWORD",
  password_confirmation: "USER_PASSWORD"
)'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

WireGuard™ is a registered trademark of Jason A. Donenfeld.
