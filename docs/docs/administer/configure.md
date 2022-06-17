---
title: Configure
sidebar_position: 1
---

Firezone leverages [Chef Omnibus](https://github.com/chef/omnibus) to handle
release packaging, process supervision, log management, and more.

The main configuration file is written in [Ruby](https://ruby-lang.org) and can
be found at `/etc/firezone/firezone.rb`. Changing this file **requires
re-running** `sudo firezone-ctl reconfigure` which triggers Chef to pick up the
changes and apply them to the running system.

For an exhaustive list of configuration variables and their descriptions, see the
[configuration file reference](../reference/configuration-file).
