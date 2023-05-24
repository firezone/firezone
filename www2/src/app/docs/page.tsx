import ReactMarkdown from 'react-markdown'
import SupportOptions from '@/components/SupportOptions'

export default function DocsHome() {
  return (
    <>
      <ReactMarkdown>
        [Firezone](/) is an open-source secure remote access
        platform that can be deployed on your own infrastructure in minutes.
        Use it to **quickly and easily** secure access to
        your private network and internal applications from an intuitive web UI.

        ![Architecture](https://user-images.githubusercontent.com/52545545/183804397-ae81ca4e-6972-41f9-80d4-b431a077119d.png)

        These docs explain how to deploy, configure, and use Firezone.

        ## Quick start

        1. [Deploy](deploy): A step-by-step walk-through setting up Firezone.
          Start here if you are new.
        1. [Authenticate](authenticate): Set up authentication using local
          email/password, OpenID Connect, or SAML 2.0 and optionally enable
          TOTP-based MFA.
        1. [Administer](administer): Day to day administration of the Firezone
          server.
        1. [User Guides](user-guides): Useful guides to help you learn how to use
          Firezone and troubleshoot common issues. Consult this section
          after you successfully deploy the Firezone server.

        ## Common configuration guides

        1. [Split Tunneling](./user-guides/use-cases/split-tunnel):
          Only route traffic to certain IP ranges through the VPN.
        1. [Setting up a NAT Gateway with a Static IP](./user-guides/use-cases/nat-gateway):
          Configure Firezone with a static IP address to provide
          a single egress IP for your team&#39;s traffic.
        1. [Reverse Tunnels](./user-guides/use-cases/reverse-tunnel):
          Establish tunnels between multiple peers.
      </ReactMarkdown>
      <SupportOptions />
      <ReactMarkdown>
        ## Contribute to firezone

        We deeply appreciate any and all contributions to the project and do our best to
        ensure your contribution is included. To get started, see [CONTRIBUTING.md
        ](https://github.com/firezone/firezone/blob/master/CONTRIBUTING.md).

      </ReactMarkdown>
    </>
  )
}
