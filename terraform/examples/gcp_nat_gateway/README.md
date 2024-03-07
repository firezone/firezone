# GCP NAT Gateway Example

In this example, we will deploy one or more Gateways in a single VPC on Google
Cloud Platform (GCP) that are configured to egress traffic through a single
Cloud NAT that is assigned a single static IP address.

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

All Gateways deployed in this example will automatically failover and load
balance for each other. No other configuration is necessary. To perform upgrades
with downtime, see [upgrading](#upgrading).

## Prerequisites

1. [Terraform](https://www.terraform.io/downloads.html)
1. [Google Cloud Platform (GCP) account](https://cloud.google.com/)
1. [Google Cloud SDK](https://cloud.google.com/sdk/docs/install)
1. A [Firezone Site](https://www.firezone.dev/kb/deploy/sites) dedicated to use
   for this example. This Site should contain **only** the Gateway(s) deployed
   in this example and any associated Resources.
1. A Firezone Gateway token. See
   [Multiple Gateways](https://www.firezone.dev/kb/deploy/gateways#deploy-multiple-gateways)
   for instructions on how to obtain a Gateway token that can be used across
   multiple instances.

## Input variables

Variables in **bold** are required.

| Name           | Description                                                            |  Type  |  Default   |
| -------------- | ---------------------------------------------------------------------- | :----: | :--------: |
| **project_id** | The project ID to deploy the Gateway(s) into.                          | string |     -      |
| **region**     | The region to deploy the Gateway(s) into. E.g. `us-west1`              | string |     -      |
| **zone**       | The availability zone to deploy the Gateway(s) into. E.g. `us-west1-a` | string |     -      |
| **token**      | The token used to authenticate the Gateway with Firezone.              | string |     -      |
| machine_type   | The type of GCP instance to deploy the Gateway(s) as.                  | string | `f1-micro` |
| replicas       | The number of Gateways to deploy.                                      | number |     3      |

## Sizing

Simply update the number of replicas to deploy more or fewer Gateways. There's
no limit to the number of Gateways you can deploy in a single VPC.

We've tested with `f1-micro` instances which still work quite well for most
applications. However, you may want to consider a larger instance type if you
have a high volume of traffic or lots of concurrent connections.

## Deployment

1. Set the necessary Terraform variables in a `terraform.tfvars` file. For
   example:

   ```hcl
   project_id = "my-gcp-project"
   region     = "us-west1"
   zone       = "us-west1-a"
   token      = "<YOUR GATEWAY TOKEN>"
   ```

1. Run `terraform init` to initialize the working directory and download the
   required providers.
1. Run `terraform apply` to deploy the Gateway(s) into your GCP project.

You can see the static IP address assigned to the Cloud NAT in the Terraform
output. This is the IP address that your Gateway(s) will use to egress traffic.

You can verify all Gateways are using this IP by viewing the Site in the
Firezone admin portal:

<center>

![Online Gateways](./online-gateways.png)

</center>

## Upgrading

To upgrade the Gateway(s) to the latest version, simply update the `token` and
issue a `terraform apply` which will trigger a redeployment of the Gateway(s).

This will incur about a minute or two of downtime as Terraform destroys the
existing Gateway(s) and deploys new ones in their place.

### Minimal downtime upgrades

To achieve a minimal downtime upgrade, add more
`google_compute_instance_template`s, each with their own `token`. When it comes
time to upgrade, update the `token` variable for each one individually, issuing
a `terraform apply` in between. We recommend 3 or more
`google_compute_instance_template`s if you plan to use this method.

This will ensure that at least two groups of Gateways are always online and
serving traffic as you roll over the old ones.
