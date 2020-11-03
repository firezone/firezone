![Test](https://github.com/CloudFire-LLC/fireguard/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/CloudFire-LLC/fireguard/badge.svg?branch=master)](https://coveralls.io/github/CloudFire-LLC/fireguard?branch=master)

**Warning**: This project is under active development and is not secure at the moment.
Do not attempt to use this software in any production capacity until this notice is removed.

You have been warned.

# FireGuard

1. [Intro](#intro)
2. [Architecture](#architecture)
3. [Setup](#setup)
4. [Usage](#usage)
5. [Contributing](#contributing)

## Intro

FireGuard is a host-it-yourself VPN and firewall configurable through a Web UI.
It aims to be a simple way to setup a VPN and optional firewall for all your
devices.

Use FireGuard to:

- Set up your own VPN
- Block, inspect, or capture outgoing traffic from your phone / tablet /
  computer to any IP(s)

## Architecture

FireGuard is written in the Elixir programming language and composed as an [Umbrella
project](https://elixir-lang.org/getting-started/mix-otp/dependencies-and-umbrella-projects.html)
consisting of three Elixir packages:

- [apps/fg_http](apps/fg_http): The Web Application
- [apps/fg_wall](apps/fg_wall): Firewall Management Process
- [apps/fg_vpn](apps/fg_vpn): WireGuard™ Management Process

For now, FireGuard assumes these apps are all running on the same host.

## Setup

Currently, the only supported method of running FireGuard is locally. MacOS and
Linux users shouldn't have any problems. Windows will Probably Work™.

You'll need recent versions of the following tools installed:

- ansible
- vagrant
- VirtualBox

With the above installed, you should be able to navigate into the project root
and just run:

```
$ vagrant up
```

This will download the VM base box, provision it with dependencies, bootstrap
the FireGuard DB, launch the FireGuard Services, and print instructions for
connecting to the Web UI.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
