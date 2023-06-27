# Contributing

Thanks for considering contributing to Firezone! Please read this guide to get
started.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
  - [Docker Setup](#docker-setup)
    - [Docker Caveat](#docker-caveat)
  - [Bootstrapping](#bootstrapping)
  - [Ensure Everything Works](#ensure-everything-works)
- [Developer Environment Setup](#developer-environment-setup)
  - [Git Commit Signing](#git-commit-signing)
  - [asdf-vm](#asdf-vm-setup)
  - [Pre-commit](#pre-commit)
  - [Elixir Development](#elixir-development)
  - [Rust Development](#rust-development)
- [Reporting Bugs](#reporting-bugs)
- [Opening a Pull Request](#opening-a-pull-request)
  - [Run Tests](#run-tests)
    - [Unit Tests](#unit-tests)
    - [End-to-end Tests](#end-to-end-tests)
  - [Use Detailed Commit Messages](#use-detailed-commit-messages)
  - [Ensure Static Analysis Checks Pass](#ensure-static-analysis-checks-pass)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Asking for Help](#asking-for-help)

## Overview

We deeply appreciate any and all contributions to the project and do our best to
ensure your contribution is included.

To maximize your chances of getting your pull request approved, please abide by
the following general guidelines:

1. Please adhere to our [code of conduct](CODE_OF_CONDUCT.md).
1. Please test with your code and include unit tests when possible.
1. It is up to you, the contributor, to make a case for why your change is a
   good idea.
1. For any security issues, please **do not** open a Github Issue. Please
   follow responsible disclosure practices laid out in
   [SECURITY.md](SECURITY.md)

## Quick Start

The goal of the quick start guide is to get an environment up and running quickly
to allow you to get a feel for all of the various components that make up Firezone.

Once you've verified all components are running successfully, the detailed developer
guides can help with getting you setup to develop on a specific Firezone component.

### Docker Setup

We recommend [Docker Desktop](https://docs.docker.com/engine/install/#desktop)
even if you're developing on Linux. This is what the Firezone core devs use and
comes with `compose` included.

#### Docker Caveat

Routing packets from the host's WireGuard client through the Firezone compose
cluster and out to the external network will not work. This is because Docker
Desktop
[rewrites the source address from containers to appear as if they originated the
host](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/)
, causing a routing loop:

1. Packet originates on Host
1. Enters WireGuard client tunnel
1. Forwarding through the Docker bridge net
1. Forward to the Firezone container `127.0.0.1:51820`
1. Firezone sends packet back out
1. Docker bridge net, Docker rewrites src IP to Host's LAN IP, (d'oh!)
1. Docker sends packet out to Host ->
1. Packet now has same src IP and dest IP as step 1 above, and the cycle
   continues

However, packets destined for Firezone compose cluster IPs (`172.28.0.0/16`)
reach their destination through the tunnel just fine. Because of this, it's
recommended to use `172.28.0.0/16` for your `AllowedIPs` parameter when using
host-based WireGuard clients with Firezone running under Docker Desktop.

Routing packets from _another_ host on the local network, through your development
machine, and out to the external Internet should work as well.

### Bootstrapping

To start the local Firezone cluster, follow these steps:

```
docker compose build
docker compose up -d postgres
docker compose run --rm elixir /bin/sh -c "cd apps/domain && mix ecto.create && mix ecto.migrate && mix ecto.seed"

# Before moving to the next step, copy the Firezone account UUID from the seed step
# Here's an example of the output
    Created accounts:
    c89bcc8c-9392-4dae-a40d-888aef6d28e0: Firezone Account

docker compose up -d api web vault gateway client relay
```

You should now be able to connect to `http://localhost:8080/<account-uuid-here>/sign_in`
and sign in with the following credentials:
```
Email:    firezone@localhost
Password: Firezone1234
```

The [`docker-compose.yml`](docker-compose.yml) file configures the Docker
development environment. If you make any changes you feel would benefit
all developers, feel free to open a PR to get them merged!

### Ensure Everything Works

```
#TODO
```

## Developer Environment Setup

### Git Commit Signing

Firezone requires that all commits in the repository be signed.  If you need assistance
setting up `git` to sign commits, please read over the Github pages for
[Managing Commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification)

### Docker Setup

Docker is the preferred method of developing Firezone locally. It (mostly)
works cross-platform, and can be used to develop Firezone on all three
major desktop OS.

If you have followed the [Docker Setup](#docker-setup) instructions in the Quick Start
section, you can move along to the next step in the development environment setup.
If you have not read the Docker Setup instructions we recommend following the directions
listed there to get your Docker environment setup properly.

### asdf-vm Setup

While not strictly required, we use [asdf-vm](https://asdf-vm.com) to manage
language versions for Firezone. You'll need to install the language runtimes
according to the versions laid out in the [.tool-versions](.tool-versions) file.

If using asdf, simply run `asdf install` from the project root.
* Note: For a fresh install of `asdf` you will need to install some
  [asdf-plugins](https://asdf-vm.com/manage/plugins.html). Running `asdf install`
  will show which `asdf` plugins need to be installed prior to installing the
  required language runtimes.

This is used to run static analysis checks during [pre-commit](#pre-commit) and
for any local, non-Docker development or testing.

### Pre-commit

We use [pre-commit](https://pre-commit.com) to catch any static analysis issues
before code is committed. Install with Homebrew: `brew install pre-commit` or
pip: `pip install pre-commit`.

### Elixir Development

If you are interested in contributing to the Web Application/API, please read the
detailed info found in the [Elixir Developer Guide](elixir/README.md)

### Rust Development

If you are interested in contributing to the Gateway, Relay, or client library,
please read the detailed info found in the [Rust Developer Guide](rust/README.md)

## Reporting Bugs

We appreciate any and all bug reports.

To report a bug, please first [search for it in our issues
tracker](https://github.com/firezone/firezone/issues). Be sure to search closed
issues as well.

If it's not there, please open a new issue and include the following:

- Description of the problem
- Expected behavior
- Steps to reproduce
- Estimated impact: High/Medium/Low
- Firezone version
- Platform architecture (amd64, aarch64, etc)
- Linux distribution
- Linux kernel version

## Opening a Pull Request

We love pull requests! To ensure your pull request gets reviewed and merged
swiftly, please read the below _before_ opening a pull request.

### Run Tests

Please test your code. As a contributor, it is **your** responsibility to ensure
your code is bug-free, otherwise it may be rejected. It's also a good idea to
check the code coverage report to ensure your tests are covering your new
code. E.g.

#### Unit Tests

Unit tests can be run with `mix test` from the project root.

To view line coverage information, you may run `mix coveralls.html`
which will generate an HTML coverage report in `cover/`.

#### End-to-end Tests

More comprehensive e2e testing is performed in the CI pipeline, but for security
reasons these will not be triggered automatically by your pull request and must
be manually triggered by a reviewer.

### Use Detailed Commit Messages

This will help tremendously during our release engineering process.

Please use the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#specification)
standard to write your commit message.

E.g.

```bash
read -r -d '' COMMIT_MSG << EOM
Updating the foobar widget to support additional widths

Additional widths are needed to various device screen sizes.
Closes #72
EOM

git commit -m "$COMMIT_MSG"
```

### Ensure Static Analysis Checks Pass

This should run automatically when you run `git commit`, but in case it doesn't:

```bash
pre-commit run --all-files
```

## Asking For Help

If you get stuck, don't hesitate to ask for help on our [community forums](https://discourse.firez.one/?utm_source=contributing).
