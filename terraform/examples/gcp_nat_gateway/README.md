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

| Name             | Description                                                   |  Type  | Default |
| ---------------- | ------------------------------------------------------------- | :----: | :-----: |
| **project_id**   | The GCP project ID to deploy the Gateway(s) into.             | string |    -    |
| **zone**         | The GCP zone to deploy the Gateway(s) into. E.g. `us-west1-a` | string |    -    |
| **machine_type** | The type of GCP instance to deploy the Gateway(s) as.         | string |    -    |
| **token**        | The token used to authenticate the Gateway with Firezone.     | string |    -    |
| replicas         | The number of Gateways to deploy.                             | number |    3    |
