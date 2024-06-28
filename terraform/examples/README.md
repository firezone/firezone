# Terraform Examples

This directory contains examples of how to use Terraform to deploy Firezone
Gateways to your infrastructure.

## Examples

Each example below is self-contained and includes a `README.md` with
instructions on how to deploy the example.

### AWS

- [NAT Gateway](./aws/nat-gateway): This example shows how to deploy one or more
  Firezone Gateways in a single AWS VPC that is configured with a NAT Gateway
  for egress. Read this if you're looking to deploy Firezone Gateways behind a
  single, shared static IP address on AWS.

### Google Cloud Platform (GCP)

- [NAT Gateway](./google-cloud/nat-gateway): This example shows how to deploy
  one or more Firezone Gateways in a single GCP VPC that is configured with a
  Cloud NAT for egress. Read this if you're looking to deploy Firezone Gateways
  behind a single, shared static IP address on GCP.
