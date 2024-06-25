# AWS NAT Gateway Example

In this example, we will deploy one or more Firezone Gateways in a single VPC on
Google Cloud Platform (GCP) that are configured to egress traffic through a
single AWS NAT Gateway that is assigned a public IPv4 and IPv6 address.

This example uses our
[AWS NAT Gateway module](../../../modules/aws/nat-gateway/).

## Common use cases

Use this guide to give your Firezone Clients a static public IP address for
egress traffic to particular Resource(s). Here are some common use cases for
this example:

- Use IP whitelisting to access a third-party or partner application such as a
  client's DB or third-party API.
- Use IP whitelisting with your identity provider to lock down access to a
  public application.
- Enabling a team of remote contractors access to a regionally-locked
  application or service.

## High availability

All Firezone Gateways deployed in this example will automatically failover and
load balance for each other. No other configuration is necessary.

## Prerequisites

1. [Terraform](https://www.terraform.io/downloads.html)
1. [AWS account](https://aws.amazon.com/)
1. A [Firezone Site](https://www.firezone.dev/kb/deploy/sites) dedicated to use
   for this example. This Site should contain **only** the Firezone Gateway(s)
   deployed in this example and any associated Resources.
1. A Firezone Gateway token. See
   [Multiple Gateways](https://www.firezone.dev/kb/deploy/gateways#deploy-multiple-gateways)
   for instructions on how to obtain a Firezone Gateway token that can be used
   across multiple instances.

## Sizing

Simply update the number of replicas to deploy more or fewer Firezone Gateways.
There's no limit to the number of Firezone Gateways you can deploy in a single
VPC.

We've tested with `t2.micro` instances which still work quite well for most
applications. However, you may want to consider a larger instance type if you
have a high volume of traffic or lots of concurrent connections.

## Deployment

1. Configure the `example.tf` file in this directory with your desired settings.
1. Run `terraform init` to initialize the working directory and download the
   required providers.
1. Run `terraform apply` to deploy the Firezone Gateway(s) into your GCP
   project.

You can see the IP addresses assigned to the NAT Gateway in the Terraform
output. These are the IP addresses that your Firezone Gateway(s) will share to
egress traffic.

## Upgrading

To upgrade the Firezone Gateway(s) to the latest version, simply update the
`token` and issue a `terraform apply` which will trigger a redeployment of the
Firezone Gateway(s).

This will incur about a minute or two of downtime as Terraform destroys the
existing Firezone Gateway(s) and deploys new ones in their place.

## Output

`static_ip_addresses` will contain a list of static IP addresses that you can
use to whitelist your Firezone Gateway(s) in your third-party or partner
application.

# Cleanup

To clean up the resources created by this example, run `terraform destroy`.
