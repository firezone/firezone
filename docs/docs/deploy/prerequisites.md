---
layout: default
title: Prerequisites
nav_order: 3
parent: Deploy
description: >
  This section describes the prerequisites for deploying Firezone.
---
---

Firezone requires the setup of a DNS record and matching SSL certificate for
production deployments. Not using Firezone in production? [
Skip to install the server]({% link docs/deploy/server.md %}).

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

By default, Firezone requires ports `80`, `443`, and `51820` to be open.
This can be changed in the configuration file for your Firezone instance. See the
[configuration file reference]({% link docs/reference/configuration-file.md %})
for details.

The image below shows this configuration on an AWS EC2 instance:
![Open ports](https://user-images.githubusercontent.com/52545545/154820330-1bdf7bec-1d82-4c45-99a8-89d3ba4d79ac.png){:width="600"}

\
[Previous: Resource Requirements]({%link docs/deploy/resource-requirements.md%}){:.btn.mr-2}
[Next: Install Server]({%link docs/deploy/server.md%}){:.btn.btn-purple}
