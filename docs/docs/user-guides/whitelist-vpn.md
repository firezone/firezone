---
layout: default
title: IP Whitelisting via VPN
nav_order: 6
parent: User Guides
description: >
  Configure a VPN server with a static IP address to simplify
  IP whitelist management and add additional security.
---
---

This guide will walk through a simple example restricting access for a
self-hosted web app to a single whitelisted static IP running Firezone.
In this example the protected resource and Firezone are
in separate VPC regions.

This arrangement is commonly done in place of maintaining a whitelist for
multiple end users, which may become labor intensive to manage as the access
list grows.

![Architecture](https://user-images.githubusercontent.com/52545545/154868328-688067dd-deca-4548-ac9d-f6ffe7eacf86.png){:width="600"}

## AWS Example

Our goal is to configure VPN traffic to the restricted resource to be routed
through a Firezone server on an EC2 instance.

### Step 1 - Deploy Firezone server

In this example, a Firezone instance has been set up on a `tc2.micro`
EC2 instance. See the
[Deployment Guide]({% link docs/deploy/index.md %})
for details on deploying Firezone. Specific to AWS, ensure:

1. The security group of the Firezone EC2 instance allows outbound traffic to the
IP of the protected resource.
1. An Elastic IP is associated with the Firezone instance. This will be the
source IP address of traffic routed through the Firezone instance to external destinations.
In this case the IP is `52.202.88.54`.

![Allocate Elastic IP](https://user-images.githubusercontent.com/52545545/154821256-9335703b-a120-4a9d-b9f5-bbca673cef63.png){:width="600"}

### Step 2 - Restrict access to the protected resource

In this example, the protected resource is a self-hosted web app. Access to the
web app is restricted to only requests from `52.202.88.54`.
Depending on the resource, inbound traffic on different ports and traffic types
may need to be allowed. This is outside the scope of this guide.

![Configure Security Group](https://user-images.githubusercontent.com/52545545/154821653-160f91d4-44d1-4b6c-b453-31604be930dc.png){:width="600"}

If the protected resource is controlled by a 3rd party, please inform the 3rd
party to allow traffic from the static IP set in Step 1 (in this case `52.202.88.54`).

### Step 3 - Route traffic to the protected resource through the VPN server

By default all traffic from users will be routed through the VPN server,
and will originate from the static IP set in Step 1 (in this case `52.202.88.54`).
However, if
[split tunneling]({% link docs/user-guides/split-tunnel.md %})
has been enabled, configuration may be required to ensure the destination IP of
the protected resource is included in the `Allowed IPs`.

\
[Related: Authentication]({%link docs/user-guides/authentication.md%}){:.btn.btn-purple}
