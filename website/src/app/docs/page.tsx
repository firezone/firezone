import Image from "next/image";
import SupportOptions from "@/components/SupportOptions";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Home",
  description: "Firezone Documentation",
};

export default function DocsHome() {
  return (
    <div>
      <header>
        <h1>Overview</h1>
      </header>
      <p>
        <a href="/">Firezone</a> is an open-source secure remote access platform
        that can be deployed on your own infrastructure in minutes. Use it to
        <strong>quickly and easily</strong> secure access to your private
        network and internal applications from an intuitive web UI.
      </p>
      <p>
        <Image
          fill={true}
          src="https://user-images.githubusercontent.com/52545545/183804397-ae81ca4e-6972-41f9-80d4-b431a077119d.png"
          alt="Architecture"
        />
      </p>
      <p>These docs explain how to deploy, configure, and use Firezone.</p>
      <h2>Quick start</h2>
      <ol>
        <li>
          <a href="/docs/deploy/">Deploy</a>: A step-by-step walk-through
          setting up Firezone. Start here if you are new.
        </li>
        <li>
          <a href="/docs/authenticate/">Authenticate</a>: Set up authentication
          using local email/password, OpenID Connect, or SAML 2.0 and optionally
          enable TOTP-based MFA.
        </li>
        <li>
          <a href="/docs/administer/">Administer</a>: Day to day administration
          of the Firezone server.
        </li>
        <li>
          <a href="/docs/user-guides/">User Guides</a>: Useful guides to help
          you learn how to use Firezone and troubleshoot common issues. Consult
          this section after you successfully deploy the Firezone server.
        </li>
      </ol>
      <h2>Common configuration guides</h2>
      <ol>
        <li>
          <a href="/docs/user-guides/use-cases/split-tunnel/">
            Split Tunneling
          </a>
          : Only route traffic to certain IP ranges through the VPN.
        </li>
        <li>
          <a href="/docs/user-guides/use-cases/nat-gateway/">
            Setting up a NAT Gateway with a Static IP
          </a>
          : Configure Firezone with a static IP address to provide a single
          egress IP for your team&#39;s traffic.
        </li>
        <li>
          <a href="/docs/user-guides/use-cases/reverse-tunnel/">
            Reverse Tunnels
          </a>
          : Establish tunnels between multiple peers.
        </li>
      </ol>
      <h2>Contribute to firezone</h2>
      <p>
        We deeply appreciate any and all contributions to the project and do our
        best to ensure your contribution is included. To get started, see
        <a
          href="https://github.com/firezone/firezone/blob/master/CONTRIBUTING.md"
          target="_blank"
          rel="noopener noreferrer"
        >
          CONTRIBUTING.md
        </a>
        .
      </p>
    </div>
  );
}
