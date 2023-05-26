"use client";

import { Alert, Tabs } from "flowbite-react";
import DefaultLink from "@/components/DefaultLink";

const metadata = {
  description:
    "Install Firezone's WireGuard®-based secure access platform on a support host using our Docker (recommended) or Omnibus deployment methods.",
};

export default function Page() {
  return (
    <div>
      <h1>Deploy Firezone</h1>

      <p>
        Firezone can be deployed on most Docker-supported platforms in a couple
        of minutes. Read more below to get started.
      </p>

      <h2> Step 1: Prepare to deploy</h2>

      <p>
        Regardless of which deployment method you choose, you'll need to follow
        the preparation steps below before deploying Firezone to production.
      </p>

      <ol>
        <li>
          <DefaultLink href="#create-a-dns-record">
            Create a DNS record
          </DefaultLink>
        </li>
        <li>
          <DefaultLink href="#set-up-ssl">Set up SSL</DefaultLink>
        </li>
        <li>
          <DefaultLink href="#open-required-firewall-ports">
            Open required firewall ports
          </DefaultLink>
        </li>
      </ol>

      <h3> Create a DNS record</h3>

      <p>
        Firezone requires a fully-qualified domain name (e.g.
        <code>firezone.company.com</code>) for production use. You'll need to
        create the appropriate DNS record at your registrar to achieve this.
        Typically this is either an A, CNAME, or AAAA record depending on your
        requirements.
      </p>

      <h3>Set up SSL</h3>

      <p>
        You'll need a valid SSL certificate to use Firezone in a production
        capacity. Firezone supports ACME for automatic provisioning of SSL
        certificates for both Docker-based and Omnibus-based installations. This
        is recommended in most cases.
      </p>

      <Tabs.Group>
        <Tabs.Item title="Docker" active>
          <h4>Setting up ACME for Docker-based deployments</h4>
          <p>
            For Docker-based deployments, the simplest way to provision an SSL
            certificate is to use our Caddy service example in
            docker-compose.yml. Caddy uses ACME to automatically provision SSL
            certificates as long as it's available on port 80/tcp and the DNS
            record for the server is valid.
          </p>
          See the{" "}
          <DefaultLink href="/docs/deploy/docker">
            Docker deployment guide
          </DefaultLink>{" "}
          for more info.
        </Tabs.Item>
        <Tabs.Item title="Omnibus">
          <p>
            For Omnibus-based deployments, ACME is disabled by default to
            maintain compatibility with existing installations.
          </p>

          <p>To enable ACME, ensure the following conditions are met:</p>

          <ul>
            <li>
              <code>80/tcp</code> is allow inbound
            </li>
            <li>
              The bundled Firezone <code>nginx</code> service is enabled and
              functioning
            </li>
            <li>
              You have a valid DNS record assigned to this instance's public IP
            </li>
            <li>
              The following 3 settings are configured in the{" "}
              <DefaultLink href="/docs/reference/configuration-file">
                configuration file
              </DefaultLink>
              :
            </li>
            <li>
              <code>default['firezone']['external_url']</code>: The FQDN for the
              server.
            </li>
            <li>
              <code>default['firezone']['ssl']['email_address']</code>: The
              email that will be used for the issued certificates.
            </li>
            <li>
              <code>default['firezone']['ssl']['acme']['enabled']</code>: Set
              this to true to enable it.
            </li>
          </ul>
        </Tabs.Item>
      </Tabs.Group>

      <h3>Open required firewall ports</h3>

      <p>
        By default, Firezone requires ports <code>443/tcp</code> and{" "}
        <code>51820/udp</code> to be accessible for HTTPS and WireGuard traffic
        respectively. These ports can change based on what you've configured in
        the configuration file. See the{" "}
        <DefaultLink href="/docs/reference/configuration-file">
          configuration file
        </DefaultLink>{" "}
        reference for details.
      </p>

      <h3>Resource requirements</h3>

      <p>
        We recommend **starting with 1 vCPU and 1 GB of RAM and scaling up** as
        the number of users and devices grows.
      </p>

      <p>
        For Omnibus-based deployments on servers with less than 1GB of memory,
        we recommend turning on swap to prevent the Linux kernel from killing
        Firezone processes unexpectedly. When this happens, it's often difficult
        to debug and results in strange, unpredictable failure modes.
      </p>

      <p>
        For the VPN tunnels themselves, Firezone uses in-kernel WireGuard, so
        its performance should be very good. 1 vCPU should be more than enough
        to saturate a 1 Gbps link.
      </p>

      <h2>Step 2: Deploy</h2>

      <p>You have two options for deploying Firezone:</p>

      <ol>
        <li>
          <DefaultLink href="/docs/deploy/docker">Docker</DefaultLink>{" "}
          (recommended)
        </li>
        <li>
          <DefaultLink href="/docs/deploy/omnibus">Omnibus</DefaultLink>
        </li>
      </ol>

      <p>
        Docker is the easiest way to install, manage, and upgrade Firezone and
        is the preferred method of deployment.
      </p>

      <Alert color="warning">
        <p>
          Chef Infra Client, the configuration system Chef Omnibus relies on,
          has been deprecated and is{" "}
          <DefaultLink href="https://docs.chef.io/versions/">
            scheduled for End-of-Life in 2024
          </DefaultLink>
          . As such, support for Omnibus-based deployments will be removed
          starting with Firezone 0.8. To transition to Docker from Omnibus
          today, follow our{" "}
          <DefaultLink href="/docs/administer/migrate">
            migration guide
          </DefaultLink>
          .
        </p>
      </Alert>
    </div>
  );
}
