<p align="center">
  <img src="https://user-images.githubusercontent.com/167144/134594125-fadeac64-990e-4d6f-9e69-8a04487e00e0.png" alt="firezone logo" width="500"/>
</p>
<p align="center">
  <a href="https://github.com/firezone/firezone/releases">
    <img src="https://img.shields.io/github/v/release/firezone/firezone?color=%23999">
  </a>
  <a href="https://e04kusl9oz5.typeform.com/to/zahKLf3d">
    <img src="https://img.shields.io/static/v1?logo=openbugbounty&logoColor=959DA5&label=feedback&labelColor=333a41&message=submit&color=3AC358" alt="firezone Slack" />
  </a>
  <a href="https://e04kusl9oz5.typeform.com/to/rpMtkZw4">
    <img src="https://img.shields.io/static/v1?logo=slack&logoColor=959DA5&label=community&labelColor=333a41&message=join&color=611f69" alt="firezone Slack" />
  </a>
  <img src="https://img.shields.io/static/v1?logo=github&logoColor=959DA5&label=Test&labelColor=333a41&message=passing&color=3AC358" alt="firezone" />
  <img src="https://img.shields.io/static/v1?label=coverage&labelColor=333a41&message=66%&color=D7614A" alt="firezone" />
  <a href="https://twitter.com/intent/follow?screen_name=firezonevpn">
    <img src="https://img.shields.io/twitter/follow/firezonevpn?style=social&logo=twitter" alt="follow on Twitter">
  </a>
</p>


Firezone is a simple [WireGuard](https://www.wireguard.com/) based VPN server and firewall for Linux designed to be secure, easy to manage, and quick to set up.

![Architecture](https://user-images.githubusercontent.com/167144/134593363-870c982d-921b-4f0c-b210-e77c8860d9ca.png)

# What is Firezone?

Firezone can be set up in minutes to manage your WireGuard VPN through a simple web interface.

## Features

- **Fast:** [3-4 times](https://wireguard.com/performance/) faster than OpenVPN.
- **Firewall built in:** Uses [nftables](https://netfilter.org) to block
    unwanted egress traffic.
- **No dependencies:** All dependencies are bundled thanks to
    [Chef Omnibus](https://github.com/chef/omnibus).
- **Secure:** Runs unprivileged. HTTPS enforced. Encrypted cookies.

![Firezone](./apps/fz_http/assets/static/images/firezone-usage.gif)

# Deploying and Configuring

Firezone is built using [Chef Omnibus](https://github.com/chef/omnibus) which
bundles all dependences into a single distributable `.deb` or `.rpm` for your
distro. All that's needed is Linux kernel 4.19 or newer with proper WireGuard
support. We recommend Linux 5.6 or higher since [it has WireGuard
support](https://lwn.net/ml/linux-kernel/CA+55aFz5EWE9OTbzDoMfsY2ez04Qv9eg0KQhwKfyJY0vFvoD3g@mail.gmail.com/)
built-in.

## Requirements

Firezone currently supports the following Linux distributions:

| Name | Status | Notes |
| --- | --- | --- |
| CentOS 7 | **Fully-supported** | Kernel upgrade to `kernel-lt` or `kernel-ml` required. See [this guide](https://medium.com/@nazishalam07/update-centos-kernel-3-10-to-5-13-latest-9462b4f1e62c) for an example. |
| CentOS 8 | **Fully-supported** | Works as-is |
| Ubuntu 18.04 | **Fully-supported** | WireGuard must be installed: `apt install wireguard-dkms`. We also recommend updating the kernel to 5.4 or higher: `apt install linux-image-generic-hwe-18.04` |
| Ubuntu 20.04 | **Fully-supported** | Works as-is |
| Debian 10 | **Fully-supported** | Kernel upgrade required. See [this guide](https://jensd.be/968/linux/install-a-newer-kernel-in-debian-10-buster-stable) for an example. |
| Debian 11 | **Fully-supported** | Works as-is |
| Fedora 33 | **Fully-supported** | Works as-is |
| Fedora 34 | **Fully-supported** | Works as-is |

If your distro isn't listed here please [open an issue](https://github.com/firezone/firezone/issues/new/choose) and let us know.

Firezone requires a valid SSL certificate and a matching DNS record to run in
production. We recommend using [Let's Encrypt](https://letsencrypt.org) to
generate a free SSL cert for your domain.

## Installation Instructions

1. Download the relevant package for your distribution from the [releases page](https://github.com/firezone/firezone/releases).
2. Install with `sudo rpm -i firezone-<version>.rpm` or `sudo dpkg -i firezone-<version>.deb` depending on your distribution.
3. Bootstrap the application with `sudo firezone-ctl reconfigure`. This will initialize config files, set up needed services and generate the default configuration.
4. Edit the default configuration at `/etc/firezone/firezone.rb`. At a minimum, you'll need to make sure `default['firezone']['fqdn']`, `default['firezone']['url_host']`, `default['firezone']['ssl']['certificate']`, and `default['firezone']['ssl']['certificate_key']` are set properly.
5. Reconfigure the application to pick up the new changes: `sudo firezone-ctl reconfigure`.
6. Finally, create an admin user with `sudo firezone-ctl create_admin`. Check the console for the login credentials.
7. Now you should be able to log into the web UI at `https://<your-server-fqdn>`

# Using Firezone

Your Firezone installation can be managed via the `firezone-ctl` command, as shown below. Most subcommands require prefixing with `sudo`.

```shell
root@demo:~# firezone-ctl
I don't know that command.
omnibus-ctl: command (subcommand)
create_admin
  Create an Admin user
General Commands:
  cleanse
    Delete *all* firezone data, and start from scratch.
  help
    Print this help message.
  reconfigure
    Reconfigure the application.
  show-config
    Show the configuration that would be generated by reconfigure.
  uninstall
    Kill all processes and uninstall the process supervisor (data will be preserved).
  version
    Display current version of Firezone
Service Management Commands:
  graceful-kill
    Attempt a graceful stop, then SIGKILL the entire process group.
  hup
    Send the services a HUP.
  int
    Send the services an INT.
  kill
    Send the services a KILL.
  once
    Start the services if they are down. Do not restart them if they stop.
  restart
    Stop the services if they are running, then start them again.
  service-list
    List all the services (enabled services appear with a *.)
  start
    Start services if they are down, and restart them if they stop.
  status
    Show the status of all the services.
  stop
    Stop the services, and do not restart them.
  tail
    Watch the service logs of all enabled services.
  term
    Send the services a TERM.
  usr1
    Send the services a USR1.
  usr2
    Send the services a USR2.
```

User-configurable settings can be found in `/etc/firezone/firezone.rb`.
Changing this file **requires re-running** `sudo firezone-ctl reconfigure` to pick up
the changes and apply them to the running system.

## Troubleshooting

To view Firezone logs, run `sudo firezone-ctl tail`.

Occasionally, during a `sudo firezone-ctl reconfigure`, the `phoenix` will fail
to start with a `TIMEOUT` error like below:

```
================================================================================
Error executing action `restart` on resource 'runit_service[phoenix]'
================================================================================

Mixlib::ShellOut::ShellCommandFailed
------------------------------------
Expected process to exit with [0], but received '1'
---- Begin output of /opt/firezone/embedded/bin/sv restart /opt/firezone/service/phoenix ----
STDOUT: timeout: run: /opt/firezone/service/phoenix: (pid 3091432) 34s, got TERM
STDERR:
---- End output of /opt/firezone/embedded/bin/sv restart /opt/firezone/service/phoenix ----
Ran /opt/firezone/embedded/bin/sv restart /opt/firezone/service/phoenix returned 1
```

This happens because of the way phoenix handles input before fully starting up.
To workaround, simply run `sudo firezone-ctl reconfigure` once more everything
should start fine.


## Uninstalling

To completely remove Firezone and its configuration files, run the [uninstall.sh
script](https://github.com/firezone/firezone/blob/master/scripts/uninstall.sh):

`curl -L https://github.com/firezone/firezone/raw/master/scripts/uninstall.sh | sudo bash -E`

**Warning**: This will irreversibly destroy ALL Firezone data and can't be
undone.

# Getting Support
For help, feedback or contributions please join our [Slack group](https://admin.typeform.com/form/rpMtkZw4/create?block=a9c11a46-1dcf-4155-b447-0d8ce5700d5f). We're actively working to improve Firezone, and the Slack group is the best way to coordinate our efforts.

## Developing and Contributing

- See [CONTRIBUTING.md](CONTRIBUTING.md).
- Report issues and bugs in [this Github project]().

## License

WireGuard™ is a registered trademark of Jason A. Donenfeld.
