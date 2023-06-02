"use client";
import { Code, Link, P, OL, UL, H1, H2, H3 } from "@/components/Base";
import { Alert, Tabs } from "flowbite-react";

const metadata = {
  description:
    "Install Firezone's WireGuard®-based secure access platform on a support host using our Docker (recommended) or Omnibus deployment methods.",
};

export default function Page() {
  return (
    <div>
      <H1>Deploy Firezone</H1>

      <P>
        Firezone can be deployed on most Docker-supported platforms in a couple
        of minutes. Read more below to get started.
      </P>

      <H2> Step 1: Prepare to deploy</H2>

      <P>
        Regardless of which deployment method you choose, you'll need to follow
        the preparation steps below before deploying Firezone to production.
      </P>

      <OL>
        <li>
          <Link href="#create-a-dns-record">Create a DNS record</Link>
        </li>
        <li>
          <Link href="#set-up-ssl">Set up SSL</Link>
        </li>
        <li>
          <Link href="#open-required-firewall-ports">
            Open required firewall ports
          </Link>
        </li>
      </OL>

      <H3>Create a DNS record</H3>

      <P>
        Firezone requires a fully-qualified domain name (e.g.
        <Code>firezone.company.com</Code>) for production use. You'll need to
        create the appropriate DNS record at your registrar to achieve this.
        Typically this is either an A, CNAME, or AAAA record depending on your
        requirements.
      </P>

      <H3>Set up SSL</H3>

      <P>
        You'll need a valid SSL certificate to use Firezone in a production
        capacity. Firezone supports ACME for automatic provisioning of SSL
        certificates for both Docker-based and Omnibus-based installations. This
        is recommended in most cases.
      </P>

      <Tabs.Group>
        <Tabs.Item title="Docker" active>
          <h4>Setting up ACME for Docker-based deployments</h4>
          <P>
            For Docker-based deployments, the simplest way to provision an SSL
            certificate is to use our Caddy service example in
            docker-compose.yml. Caddy uses ACME to automatically provision SSL
            certificates as long as it's available on port 80/tcp and the DNS
            record for the server is valid.
          </P>
          See the{" "}
          <Link href="/docs/deploy/docker">Docker deployment guide</Link> for
          more info.
        </Tabs.Item>
        <Tabs.Item title="Omnibus">
          <P>
            For Omnibus-based deployments, ACME is disabled by default to
            maintain compatibility with existing installations.
          </P>

          <P>To enable ACME, ensure the following conditions are met:</P>

          <UL>
            <li>
              <Code>80/tcp</Code> is allow inbound
            </li>
            <li>
              The bundled Firezone <Code>nginx</Code> service is enabled and
              functioning
            </li>
            <li>
              You have a valid DNS record assigned to this instance's public IP
            </li>
            <li>
              The following 3 settings are configured in the{" "}
              <Link href="/docs/reference/configuration-file">
                configuration file
              </Link>
              :
            </li>
            <li>
              <Code>default['firezone']['external_url']</Code>: The FQDN for the
              server.
            </li>
            <li>
              <Code>default['firezone']['ssl']['email_address']</Code>: The
              email that will be used for the issued certificates.
            </li>
            <li>
              <Code>default['firezone']['ssl']['acme']['enabled']</Code>: Set
              this to true to enable it.
            </li>
          </UL>
        </Tabs.Item>
      </Tabs.Group>

      <H3>Open required firewall ports</H3>

      <P>
        By default, Firezone requires ports <Code>443/tcp</Code> and{" "}
        <Code>51820/udp</Code> to be accessible for HTTPS and WireGuard traffic
        respectively. These ports can change based on what you've configured in
        the configuration file. See the{" "}
        <Link href="/docs/reference/configuration-file">
          configuration file
        </Link>{" "}
        reference for details.
      </P>

      <H3>Resource requirements</H3>

      <P>
        We recommend{" "}
        <strong>starting with 1 vCPU and 1 GB of RAM and scaling up</strong> as
        the number of users and devices grows.
      </P>

      <P>
        For Omnibus-based deployments on servers with less than 1GB of memory,
        we recommend turning on swap to prevent the Linux kernel from killing
        Firezone processes unexpectedly. When this happens, it's often difficult
        to debug and results in strange, unpredictable failure modes.
      </P>

      <P>
        For the VPN tunnels themselves, Firezone uses in-kernel WireGuard, so
        its performance should be very good. 1 vCPU should be more than enough
        to saturate a 1 Gbps link.
      </P>

      <H2>Step 2: Deploy</H2>

      <P>You have two options for deploying Firezone:</P>

      <OL>
        <li>
          <Link href="/docs/deploy/docker">Docker</Link> (recommended)
        </li>
        <li>
          <Link href="/docs/deploy/omnibus">Omnibus</Link>
        </li>
      </OL>

      <P>
        Docker is the easiest way to install, manage, and upgrade Firezone and
        is the preferred method of deployment.
      </P>

      <Alert color="warning">
        Chef Infra Client, the configuration system Chef Omnibus relies on, has
        been deprecated and is{" "}
        <Link href="https://docs.chef.io/versions/">
          scheduled for End-of-Life in 2024
        </Link>
        . As such, support for Omnibus-based deployments will be removed
        starting with Firezone 0.8. To transition to Docker from Omnibus today,
        follow our <Link href="/docs/administer/migrate">migration guide</Link>.
      </Alert>
    </div>
  );
}
