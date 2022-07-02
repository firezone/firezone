---
title: Prerequisites
sidebar_position: 2
---

Firezone requires the setup of a DNS record and matching SSL certificate for
production deployments.

## Create a DNS record

Firezone requires a fully-qualified domain name (e.g. `firezone.company.com`)
for production use. You'll need to create the appropriate DNS record at your
registrar to achieve this. Typically this is either an A, CNAME, or AAAA record
depending on your requirements.

## Create an SSL certificate

While Firezone generates a self-signed SSL certificate for you on install,
you'll need a valid SSL certificate to use Firezone in a production capacity.

We recommend using [Let's Encrypt](https://letsencrypt.org) to
generate a free SSL cert for your domain. Firezone will include the ability to
automatically generate valid SSL certificates for you in an upcoming release,
but for now these must be generated manually and specified in the main
configuration file at `/etc/firezone/firezone.rb`. See here for a guide on how
to do so:
[https://eff-certbot.readthedocs.io/en/stable/using.html#manual](https://eff-certbot.readthedocs.io/en/stable/using.html#manual)

## Security Group and Firewall Settings

By default, Firezone requires ports `443/tcp` and `51820/udp` to be
accessible for HTTPS and WireGuard traffic respectively.
These ports can change based on what you've configured in the configuration file.
See the
[configuration file reference](../reference/configuration-file)
for details.

**NOTE**: Firezone modifies the kernel netfilter and routing tables. Other
programs that modify the Linux routing table or firewall may interfere with
Firezone's operation. For help troubleshooting connectivity issues, see
[troubleshoot](../administer/troubleshoot).

## Resource Requirements

We recommend **starting with 1 vCPU and 1 GB of RAM and scaling up** as the
number of users and bandwidth requirements grow.

Firezone uses in-kernel WireGuard, so its performance should be very good.
In general, more CPU cores translate to higher bandwidth capacity per tunnel
while more RAM will help with higher counts of users and tunnels.
