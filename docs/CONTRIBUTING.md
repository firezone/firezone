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
  - [Developer tools](#developer-tools)
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
- [Logging and sensitive info](#logging-and-sensitive-info)
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
comes with the correct version of `compose` included.

If you're using Docker Engine on Linux instead, you'll want to make sure to
[ install the compose plugin ](https://docs.docker.com/compose/install/#scenario-two-install-the-compose-plugin)
instead so that you have v2 installed.

```bash
> docker compose version
Docker Compose version v2.27.0
```

#### Bootstrapping the DB

To start the local Firezone cluster, follow these steps:

```sh
docker compose build
docker compose run --rm elixir /bin/sh -c "mix ecto.create && mix ecto.migrate && mix ecto.seed"

# Before moving to the next step, copy the Firezone account UUID from the seed step
# Here's an example of the output
    Created accounts:
    c89bcc8c-9392-4dae-a40d-888aef6d28e0: Firezone Account

docker compose up -d portal vault gateway client relay-1 relay-2
```

You should now be able to connect to `http://localhost:8080/<account-uuid-here>`
and sign in with the following credentials:

```text
Email:    firezone@localhost.local
Password: Firezone1234
```

The [`docker-compose.yml`](../docker-compose.yml) file configures the Docker
development environment. If you make any changes you feel would benefit all
developers, feel free to open a PR to get them merged!

After this you will have running:

- A portal
- A gateway connected to the portal
- A headless Linux client connected to the portal
- A relay connected to the portal
- A resource with IP `172.20.0.100` on a separate network shared with the
  gateway

### Ensure Everything Works

```sh
# To test that a client can ping the resource
docker compose exec -it client ping 172.20.0.100

# You can also directly use the client
docker compose exec -it client /bin/sh
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

### Developer tools

The versions for most tools and SDKs required for working on Firezone are managed
via `.tool-versions` files in the respective directories, i.e. Elixir tools in
[elixir/.tool-versions](../elixir/.tool-versions) etc.

You can use any `.tool-versions`-compatible version manager for installing them.

- Note: For a fresh install of `asdf` you will need to install some
  [asdf-plugins](https://asdf-vm.com/manage/plugins.html). e.g. `asdf plugin add nodejs && asdf install nodejs` to set up the NodeJS plugin and package.

This is used to run static analysis checks during [pre-commit](#pre-commit) and
for any local, non-Docker development or testing.

### Pre-commit

We use [pre-commit](https://pre-commit.com) to catch any static analysis issues
before code is committed.

- Install [Mise](https://mise.jdx.dev/) which will automatically install pre-commit and other required tools (see `mise.toml`)
- Install the repo-specific checks with `pre-commit install --config .github/pre-commit-config.yaml`

### Elixir Development

If you are interested in contributing to the Web Application/API, please read
the detailed info found in the [Elixir Developer Guide](../elixir/README.md)

### Rust Development

If you are interested in contributing to the Gateway, Relay, or client library,
please read the detailed info found in the
[Rust Developer Guide](../rust/README.md)

##### Rust development with docker

Sometimes it's useful to test your changes in a local docker, however the
`docker-compose.yml` file at the root directory requires rebuilding the images
each time you want to test the change.

To solve this, you can use the `rust/docker-compose-dev.yml` file like
`docker compose -f docker-compose.yml -f rust/docker-compose-dev.yml <command>`

This will use locally compiled binaries found at
`rust/target/x86_64-unknown-musl/debug`

You can also
[set the env variable `COMPOSE_FILE`](https://docs.docker.com/compose/environment-variables/envvars/#compose_file)
so you don't have to manually set the compose files each time.

### Shell script Development

See [scripts/README](../scripts/README.md).

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
mise run lint
```

## Logging and sensitive info

IP addresses and domain names may be logged at the DEBUG level, but not INFO or
any other level that is enabled by default in production builds.

## Asking For Help

If you get stuck, don't hesitate to ask for help on our
[community forums](https://discourse.firez.one/?utm_source=contributing).
