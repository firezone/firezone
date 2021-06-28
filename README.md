![](./apps/cf_http/assets/static.logo.svg)

![Test](https://github.com/CloudFire-LLC/cloudfire/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/CloudFire-LLC/cloudfire/badge.svg?branch=master)](https://coveralls.io/github/CloudFire-LLC/cloudfire?branch=master)

**Warning**: This project is under active development and is not secure at the moment.
Do not attempt to use this software in any production capacity until this notice is removed.

You have been warned.

# CloudFire

1. [Intro](#intro)
2. [Architecture](#architecture)
3. [Setup](#setup)
4. [Usage](#usage)
5. [Contributing](#contributing)

## Intro

CloudFire is a host-it-yourself VPN and firewall configurable through a Web UI.
It aims to be a simple way to setup a VPN and optional firewall for all your
devices.

Use CloudFire to:

- Set up your own VPN
- Block, inspect, or capture outgoing traffic from your phone / tablet /
  computer to any IP(s)

## Architecture

CloudFire is written in the Elixir programming language and composed as an [Umbrella
project](https://elixir-lang.org/getting-started/mix-otp/dependencies-and-umbrella-projects.html)
consisting of three Elixir packages:

- [apps/cf_http](apps/cf_http): The Web Application
- [apps/cf_wall](apps/cf_wall): Firewall Management Process
- [apps/cf_vpn](apps/cf_vpn): WireGuard™ Management Process

For now, CloudFire assumes these apps are all running on the same host.

## Setup

Currently, the only supported method of running CloudFire is locally. MacOS and
Linux users shouldn't have any problems. Windows will Probably Work™.

You'll need recent versions of the following tools installed:

- ansible
- vagrant
- VirtualBox

With the above installed, you should be able to navigate into the project root
and just run:

```bash
vagrant up
```

This will download the VM base box, provision it with dependencies, bootstrap
the CloudFire DB, launch the CloudFire Services, and print instructions for
connecting to the Web UI.

## Creating Additional Users

CloudFire creates the first user for you upon installation and prints the
credentials after `vagrant up` completes in the step above.

You may create additional users with the following command:

```bash
sudo -u cloudfire /opt/cloudfire/bin/cloudfire rpc 'CfHttp.Users.create_user(
  email: "USER_EMAIL",
  password: "USER_PASSWORD",
  password_confirmation: "USER_PASSWORD"
)'
```

This will create a user you can use to log into the Web UI.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
