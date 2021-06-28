# Contributing Guide

Read this guide before opening a pull request.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Project Setup](#project-setup)
   1. [Provision the test VMs](#provision-the-test-vms)
   2. [Start the WireGuard™ interface on the
      server](#start-the-wireguard-interface-on-the-server)
   3. [Start the WireGuard interface on the
      client](#start-the-wireguard-interface-on-the-client)
3. [Testing](#testing)
   TBD

## Prerequisites

You'll need the following software installed to develop for CloudFire:

- [Vagrant](vagrantup.com)
- [Ansible](ansible.com)
- [VirtualBox](virtualbox.org)
- [asdf VM](asdf-vm.com)
- A recent version of [PostgreSQL](postgresql.org) server installed and running
- [dotenv](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/dotenv)
  functionality for your shell

## Project Setup

1. Ensure Postgres is running with a superuser role of `cloudfire`. E.g.
  ```
  $ psql -h localhost -d postgres

  > CREATE ROLE cloudfire;
  ```
2. Install the language versions defined in `.tool-versions`:
  ```
  # Run this from the project root
  $ asdf install
  ```
3. Resolve dependencies
  ```
  $ mix deps.get
  $ npm install --prefix apps/cf_http/assets
  ```
4. Bootstrap DB
  ```
  $ mix ecto.setup
  ```
5. Launch Server
  ```
  mix phx.server
  ```

## Testing

Run tests with `mix test` from the project root.
