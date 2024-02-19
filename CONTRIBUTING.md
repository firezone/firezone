# Contributing

Thanks for considering contributing to Firezone! Please read this guide to get
started.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
  - [Docker Setup](#docker-setup)
    - [Test With Docker](#test-with-docker)
  - [Bootstrapping](#bootstrapping)
  - [Ensure Everything Works](#ensure-everything-works)
- [Developer Environment Setup](#developer-environment-setup)
  - [Git Commit Signing](#git-commit-signing)
  - [asdf-vm](#asdf-vm-setup)
  - [Pre-commit](#pre-commit)
  - [Elixir Development](#elixir-development)
  - [Rust Development](#rust-development)
  - [Shell script Development](#shell-script-development)
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
1. Please test your code and include unit tests when possible.
1. It is up to you, the contributor, to make a case for why your change is a
   good idea.
1. For any security issues, please **do not** open a Github Issue. Please follow
   responsible disclosure practices laid out in [SECURITY.md](SECURITY.md)

## Quick Start

The goal of the quick start guide is to get an environment up and running
quickly to allow you to get a feel for all of the various components that make
up Firezone.

Once you've verified all components are running successfully, the detailed
developer guides can help with getting you setup to develop on a specific
Firezone component.

### Docker Setup

We recommend [Docker Desktop](https://docs.docker.com/engine/install/#desktop)
even if you're developing on Linux. This is what the Firezone core devs use and
comes with `compose` included.

#### Test With Docker

When you want to test every component together the ideal way to go is to use
docker.

To do this you first need a seeded database, for that follow the steps on the
[Elixir's README](elixir/readme#running-control-plane-for-local-development).
Then you can do:

```sh
# To start all the components
docker compose up -d --build

# To check the logs
docker compose logs -f
```

After this you will have running:

- A portal
- A gateway connected to the portal
- A headless Linux client connected to the portal
- A relay connected to the portal
- A resource with IP `172.20.0.100` on a separate network shared with the
  gateway

```sh
# To test that a client can ping the resource
docker compose exec -it client ping 172.20.0.100

# You can also directly use the client
docker compose exec -it client /bin/sh
```

### Bootstrapping

To start the local Firezone cluster, follow these steps:

```
docker compose build
docker compose run --rm elixir /bin/sh -c "cd apps/domain && mix ecto.create && mix ecto.migrate && mix ecto.seed"

# Before moving to the next step, copy the Firezone account UUID from the seed step
# Here's an example of the output
    Created accounts:
    c89bcc8c-9392-4dae-a40d-888aef6d28e0: Firezone Account

docker compose up -d api web vault gateway client relay
```

You should now be able to connect to `http://localhost:8080/<account-uuid-here>`
and sign in with the following credentials:

```
Email:    firezone@localhost
Password: Firezone1234
```

The [`docker-compose.yml`](docker-compose.yml) file configures the Docker
development environment. If you make any changes you feel would benefit all
developers, feel free to open a PR to get them merged!

### Ensure Everything Works

```
#TODO
```

## Developer Environment Setup

### Git Commit Signing

Firezone requires that all commits in the repository be signed. If you need
assistance setting up `git` to sign commits, please read over the Github pages
for
[Managing Commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification)

### Docker Setup

Docker is the preferred method of developing Firezone locally. It (mostly) works
cross-platform, and can be used to develop Firezone on all three major desktop
OS.

If you have followed the [Docker Setup](#docker-setup) instructions in the Quick
Start section, you can move along to the next step in the development
environment setup. If you have not read the Docker Setup instructions we
recommend following the directions listed there to get your Docker environment
setup properly.

### asdf-vm Setup

While not strictly required, we use [asdf-vm](https://asdf-vm.com) to manage
language versions for Firezone. You'll need to install the language runtimes
according to the versions laid out in the [.tool-versions](.tool-versions) file.

If using asdf, simply run `asdf install` from the project root.

- Note: For a fresh install of `asdf` you will need to install some
  [asdf-plugins](https://asdf-vm.com/manage/plugins.html). Running
  `asdf install` will show which `asdf` plugins need to be installed prior to
  installing the required language runtimes.

This is used to run static analysis checks during [pre-commit](#pre-commit) and
for any local, non-Docker development or testing.

### Pre-commit

We use [pre-commit](https://pre-commit.com) to catch any static analysis issues
before code is committed. Install with Homebrew: `brew install pre-commit` or
pip: `pip install pre-commit`.

### Elixir Development

If you are interested in contributing to the Web Application/API, please read
the detailed info found in the [Elixir Developer Guide](elixir/README.md)

### Rust Development

If you are interested in contributing to the Gateway, Relay, or client library,
please read the detailed info found in the
[Rust Developer Guide](rust/README.md)

### Shell script Development

If you are interested in contributing to any of our shell scripts, please read
the detailed info found in the [Shell script README](scripts/README.md).

## Reporting Bugs

We appreciate any and all bug reports.

To report a bug, please first
[search for it in our issues tracker](https://github.com/firezone/firezone/issues).
Be sure to search closed issues as well.

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
check the code coverage report to ensure your tests are covering your new code.
E.g.

#### Unit Tests

Unit tests can be run with `mix test` from the project root.

To view line coverage information, you may run `mix coveralls.html` which will
generate an HTML coverage report in `cover/`.

#### End-to-end Tests

More comprehensive e2e testing is performed in the CI pipeline, but for security
reasons these will not be triggered automatically by your pull request and must
be manually triggered by a reviewer.

### Use Detailed Commit Messages

This will help tremendously during our release engineering process.

Please use the
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#specification)
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

If you get stuck, don't hesitate to ask for help on our
[community forums](https://discourse.firez.one/?utm_source=contributing).
