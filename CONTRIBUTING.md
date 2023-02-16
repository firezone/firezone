# Contributing

Thanks for considering contributing to Firezone! Please read this guide to get
started.

## Table of Contents

- [Overview](#overview)
- [Developer Environment Setup](#developer-environment-setup)
  - [Docker Setup](#docker-setup)
    - [Docker Caveat](#docker-caveat)
  - [Local HTTPS](#local-https)
  - [asdf-vm](#asdf-vm)
  - [Pre-commit](#pre-commit)
  - [The .env File](#the-env-file)
  - [Bootstrapping](#bootstrapping)
  - [Ensure Everything Works](#ensure-everything-works)
- [Reporting Bugs](#reporting-bugs)
- [Opening a Pull Request](#opening-a-pull-request)
  - [Run Tests](#run-tests)
    - [Unit Tests](#unit-tests)
    - [End-to-end Tests](#end-to-end-tests)
  - [Use Detailed Commit Messages](#use-detailed-commit-messages)
  - [Ensure Static Analysis Checks Pass](#ensure-static-analysis-checks-pass)
- [Code of Conduct](#code-of-conduct)
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

## Developer Environment Setup

Docker is the preferred method of development Firezone locally. It (mostly)
works cross-platform, and can be used to develop Firezone on all three
major desktop OS. This also provides a small but somewhat realistic network
environment with working nftables and WireGuard subsystems for live development.

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
1. Forward to the Firezone container, 127.0.0.1:51820
1. Firezone sends packet back out
1. Docker bridge net, Docker rewrites src IP to Host's LAN IP, (d'oh!)
1. Docker sends packet out to Host ->
1. Packet now has same src IP and dest IP as step 1 above, and the cycle
   continues

However, packets destined for Firezone compose cluster IPs (172.28.0.0/16)
reach their destination through the tunnel just fine. Because of this, it's
recommended to use `172.28.0.0/16` for your `AllowedIPs` parameter when using
host-based WireGuard clients with Firezone running under Docker Desktop.

Routing packets from _another_ host on the local network, through your development
machine, and out to the external Internet should work as well.

### Local HTTPS

We use Caddy as a development proxy. The `docker-compose.yml` is set up to link
Caddy's local root cert into your `priv/pki/authorities/local/` directory.

Simply add the `root.crt` file to your browser and/or OS certificate store in
order to have working local HTTPS. This file is generated when Caddy launches for
the first time and will be different for each developer.

### asdf-vm Setup

While not strictly required, we use [asdf-vm](https://asdf-vm.com) to manage
language versions for Firezone. You'll need to install the language runtimes
according to the versions laid out in the [.tool-versions](.tool-versions) file.

If using asdf, simply run `asdf install` from the project root.

This is used to run static analysis checks during [pre-commit](#pre-commit) and
for any local, non-Docker development or testing.

### Pre-commit

We use [pre-commit](https://pre-commit.com) to catch any static analysis issues
before code is committed. Install with Homebrew: `brew install pre-commit` or
pip: `pip install pre-commit`.

### Bootstrapping

To start the local development cluster, follow these steps:

```
docker compose build
docker compose up -d postgres
docker compose run --rm firezone mix do ecto.setup, ecto.seed
docker compose up
```

Now you should be able to connect to `https://localhost/`
and sign in with email `firezone@localhost` and password `firezone1234`.

The [`docker-compose.yml`](docker-compose.yml) file configures the Docker
development environment. If you make any changes you feel would benefit
all developers, feel free to open a PR to get them merged!

### Ensure Everything Works

There is a `client` container in the docker-compose configuration that
can be used to simulate a WireGuard client connecting to Firezone. It's already
provisioned in the Firezone development cluster and has a corresponding
WireGuard configuration located at `priv/wg0.client.conf`.
It's attached to the `isolation` Docker network which is isolated from the other
Firezone Docker services. By connecting to Firezone from the `client`
container, you can test the WireGuard tunnel is set up correctly by pinging the
`caddy` container:

- `docker compose exec client ping 172.28.0.99`
- `docker compose exec client curl -k 172.28.0.99:8443/hello`: this
  should return `HELLO` text.

If the above commands indicate success, you should be good to go!

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
