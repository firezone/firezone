# Contributing

Thanks for considering contributing to Firezone! Please read this guide to get
started.

# Table of Contents

* [Overview](#overview)
* [Developer Environment Setup](#developer-environment-setup)
  * [Prerequisites](#prerequisites)
    * [asdf-vm](#asdf-vm)
    * [Postgresql](#postgresql)
    * [Pre-commit](#pre-commit)
  * [The .env File](#the-env-file)
  * [Bootstrapping](#bootstrapping)
* [Reporting Bugs](#reporting-bugs)
* [Opening a Pull Request](#opening-a-pull-request)
  * [Running Tests](#running-tests)
  * [Use Detailed Commit Messages](#use-detailed-commit-messages)
  * [Ensure Static Analysis Checks Pass](#ensure-static-analysis-checks-pass)
* [Code of Conduct](#code-of-conduct)
* [Asking for Help](#asking-for-help)


# Overview

We deeply appreciate any and all contributions to the project and do our best to
ensure your contribution is included.

To maximize your chances of getting your pull request approved, please abide by
the following general guidelines:

1. Please adhere to our [code of conduct](CODE_OF_CONDUCT.md).
2. Please test with your code and include unit tests when possible.
3. It is up to you, the contributor, to make a case for why your change is a
   good idea.
4. For any security issues, please **do not** open a Github Issue. Please
   follow responsible disclosure practices laid out in
   [SECURITY.md](SECURITY.md)

# Developer Environment Setup

We recommended macOS or Linux for developing for Firezone. You can (probably)
use Windows too with something like Windows subsystem for Linux, but we haven't
tried.

## Prerequisites

### asdf-vm
While not required, we use [asdf-vm](https://asdf-vm.com) to manage language
versions for Firezone. You'll need to install the language runtimes according
to the versions laid out in the [.tool-versions](.tool-versions) file.

If using asdf, simply run `asdf install` from the project root.

### Postgresql

Firezone development requires access to a Postgresql instance. Versions 9.6 or
higher should work fine. Access can be configured using the [
.env](#the-env-file) described below.

### Pre-commit

We use [pre-commit](https://pre-commit.com) to catch any static analysis issues
before code is committed. Install with Homebrew: `brew install pre-commit` or
pip: `pip install pre-commit`.

### The ENV file

In order to save local environment variables in your development environment,
you can use a `.env` file in the project root directory to store any commonly
used settings.

.env.sample will give you an example of what this file may look like.

Run the following command to 'source' the environment variables from .env on
`mix start`

`env $(cat .env | grep -v \# | xargs) mix start`

## Bootstrapping

Assuming you've completed the steps above, you should be able to get everything
set up like this:

```bash
git clone https://github.com/firezone/firezone
cd firezone
asdf install
mix local.hex --force
mix local.rebar --force
mix deps.get
MIX_ENV=test mix do ecto.remigrate
mix test
```

This will initialize everything and run the test suite. If you have no
failures, Firezone should be properly set up 🥳.

Then, to initialize assets, create seed data, and start the dev server:
To create seed data and start the development server:

```bash
cd apps/fz_http
mix ecto.reset
npm install --prefix assets
cd ../..
mix start
```

At this point you should be able to sign in to
[http://localhost:4000](http://localhost:4000) with email `firezone@localhost` and
password `firezone1234`.

## Running this inside a Devcontainer

You can run this using Github Codespaces or your own devcontainer using Docker.

On GitHub Codespaces, follow the instructions above but start the server with
PROXY_FORWARDED enabled and pass in your Codespace external url:

`PROXY_FORWARDED=true EXTERNAL_URL=[your_devcontainer_url] MIX_ENV=dev mix start`

or using the `.env` file

`env $(cat .env | grep -v \# | xargs) mix start`

On Github Codespaces you can find your EXTERNAL_URL by issuing the following
command in the terminal:

`echo "https://${CODESPACE_NAME}-4000.githubpreview.dev"`

### Note: Devcontainer on Windows

If you are on Windows, make sure your git config `core.autocrlf` is off. Otherwise,
the `\r` characters confuses asdf, which in turn fails the devcontainer build.

# Reporting Bugs
We appreciate any and all bug reports.

To report a bug, please first [search for it in our issues
tracker](https://github.com/firezone/firezone/issues). Be sure to search closed
issues as well.

If it's not there, please open a new issue and include the following:

* Description of the problem
* Expected behavior
* Steps to reproduce
* Estimated impact: High/Medium/Low
* Firezone version
* Platform architecture (amd64, aarch64, etc)
* Linux distribution
* Linux kernel version

# Opening a Pull Request
We love pull requests! To ensure your pull request gets reviewed and merged
swiftly, please read the below *before* opening a pull request.

## Run Tests
Please test your code. As a contributor, it is **your** responsibility to ensure
your code is bug-free, otherwise it may be rejected. It's also a good idea to
check the code coverage report to ensure your tests are covering your new
code. E.g.

### Unit Tests
Unit tests can be run with `mix test` from the project root.

To view line coverage information, you may run `mix coveralls.html`
which will generate an HTML coverage report in `cover/`.

### End-to-end Tests
More comprehensive e2e testing is performed in the CI pipeline, but for security
reasons these will not be triggered automatically by your pull request and must
be manually triggered by a reviewer.

## Use Detailed Commit Messages
This will help tremendously during our release engineering process. E.g.
```bash
read -r -d '' COMMIT_MSG << EOM
Updating the foobar widget to support additional widths

Additional widths are needed to various device screen sizes.
Closes #72
EOM

git commit -m "$COMMIT_MSG"
```

## Ensure Static Analysis Checks Pass
This should run automatically when you run `git commit`, but in case it doesn't:
```bash
pre-commit run --all-files
```

# Asking For Help
If you get stuck, don't hesitate to ask for help on our mailing list at
https://discourse.firez.one.
