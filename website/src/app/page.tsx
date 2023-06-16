import { Metadata } from "next";
import InstallBlock from "@/components/InstallBlock";
import Link from "next/link";
import Image from "next/image";

export const metadata: Metadata = {
  title: "Open-source Remote Access • Firezone",
  description: "Open-source remote access built on WireGuard®.",
};

export default function Page() {
  return (
    <div className="pt-24 flex flex-col">
      <div className="hero">
        <div className="container">
          <h1 className="hero__title">Fast, effortless secure access</h1>
          <p>
            Firezone is an open-source remote access platform built on
            WireGuard®, a modern VPN protocol that's 4-6x faster than OpenVPN.
            Deploy on your infrastructure and start onboarding users in minutes.
          </p>
          <div className="row">
            <div className="col col--12">
              <center>
                <a className="button button--primary" href="/docs/deploy">
                  Deploy now
                </a>
              </center>
            </div>
          </div>
        </div>
      </div>

      <div className="container">
        <Image
          width={960}
          height={540}
          alt="Overview gif"
          src="https://user-images.githubusercontent.com/167144/218759566-acaffd2e-ef37-4b42-a014-bfaa8d33e655.gif"
        />
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2 className="margin-bottom--lg">Trusted by organizations like</h2>
      </center>

      <div className="container">
        <div className="row">
          <div className="col col--2">
            <Image
              alt="bunq logo"
              src="https://user-images.githubusercontent.com/167144/218763171-3b768826-eddf-499c-9b84-5ad365e8da6e.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="tribe logo"
              src="https://user-images.githubusercontent.com/167144/218763181-61c8b4a7-4367-41a6-a790-0fa2b2a34461.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="poughkeepsie logo"
              src="https://user-images.githubusercontent.com/167144/218763199-69def673-f37d-4e6b-aee9-13eac24ad93b.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="rebank logo"
              src="https://user-images.githubusercontent.com/167144/218763213-265a562c-1ed0-4206-8a9f-6726aaaaeed4.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="square1 logo"
              src="https://user-images.githubusercontent.com/167144/218763233-ac4fd4f2-c58b-4136-a3b1-ceeb09a4f954.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="db11 logo"
              src="https://user-images.githubusercontent.com/167144/218763247-e75a2410-baa0-45f8-bd5f-aa33d5fd0898.png"
              width={100}
              height={55}
            />
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="hero">
        <div className="container">
          <h1 className="hero__title">An alternative to old VPNs</h1>
        </div>
      </div>

      {/* Feature 1 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Streamline workflows. Reduce total cost of ownership.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            <p>
              Legacy VPNs are cumbersome to manage and take weeks to configure
              correctly. Firezone takes minutes to deploy and the Web GUI makes
              managing secure access effortless for admins.
            </p>
            <ul>
              <li>Integrate any identity provider to enforce 2FA / MFA</li>
              <li>Define user-scoped access rules</li>
              <li>Manage users with a snappy admin dashboard</li>
            </ul>
          </div>
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 1"
              src="https://user-images.githubusercontent.com/167144/218778243-37f22d1e-0bdf-4f3d-8859-4b81dd91878a.png"
            />
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      {/* Feature 2 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            High throughput and low latency. Up to 4-6x faster than OpenVPN.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 2"
              src="https://user-images.githubusercontent.com/167144/218778241-c2baa6d1-499a-4da3-a9d3-7e0d4590f75f.png"
            />
            <p>
              <Link href="https://core.ac.uk/download/pdf/322886318.pdf">
                Performance comparison of VPN solutions (Osswald et al.)
              </Link>
            </p>
          </div>
          <div className="col col--6">
            <p>
              Increase productivity and decrease connection issues for your
              remote team. Firezone uses kernel WireGuard® to be efficient,
              reliable, and performant in any environment.
            </p>
            <ul>
              <li>
                <Link href="https://www.wireguard.com/protocol/">
                  State-of-the-art cryptography
                </Link>
              </li>
              <li>
                <Link href="https://www.wireguard.com/formal-verification/">
                  Auditable and formally verified
                </Link>
              </li>
              <li>
                <Link href="https://www.wireguard.com/performance/">
                  Multi-threaded
                </Link>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      {/* Feature 3 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Firezone runs entirely on your infrastructure. No vendor lock-in.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            Deploy Firezone on any platform that supports Docker. There's no
            need to risk breaches by sending data to third parties.
            <ul>
              <li>VPC, data center, or on-prem</li>
              <li>Auto-renewing SSL certs from Let's Encrypt via ACME</li>
              <li>Flexible and configurable</li>
            </ul>
          </div>
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 3"
              src="https://user-images.githubusercontent.com/167144/218778234-b8150dcb-5af1-410a-8c16-95c660171d81.png"
            />
            <Link href="/docs/deploy">
              Explore the deployment documentation &gt;
            </Link>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Integrate your identity provider for SSO to enforce 2FA / MFA.
          </h2>
        </center>
        <p>
          Only allow connections from authenticated users and automatically
          disable access for employees who have left. Firezone integrates with
          any OIDC and SAML 2.0 compatible identity provider for single sign-on
          (SSO).
        </p>
      </div>

      <div className="container">
        <div className="row">
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/keycloak/">
              <Image
                width={109}
                height={41}
                alt="keycloak logo"
                src="https://user-images.githubusercontent.com/167144/218770941-2d8cdf09-d1f4-48bb-9049-b8dc486d909a.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/google/">
              <Image
                width={109}
                height={41}
                alt="google logo"
                src="https://user-images.githubusercontent.com/167144/218770954-e41318d4-a8b1-40e5-ab4a-3343d63013a0.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/okta/">
              <Image
                width={109}
                height={41}
                alt="okta logo"
                src="https://user-images.githubusercontent.com/167144/218770967-9615c64a-c948-448b-9019-0226c1e3e086.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/onelogin/">
              <Image
                width={109}
                height={41}
                alt="onelogin logo"
                src="https://user-images.githubusercontent.com/167144/218770990-6959fb55-ebf3-417e-a75b-1981cf86bab0.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/azuread/">
              <Image
                width={109}
                height={41}
                alt="azure logo"
                src="https://user-images.githubusercontent.com/167144/218771000-ff5616d7-f391-4c75-9806-09e5bf1a6a91.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/saml/jumpcloud/">
              <Image
                width={109}
                height={41}
                alt="jumpcloud logo"
                src="https://user-images.githubusercontent.com/167144/218771019-fb525e97-ec0c-465e-8160-a547a54feab2.png"
              />
            </Link>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">Who can benefit from Firezone?</h2>
        </center>
        <p>
          Easy to deploy and manage for individuals and organizations alike.
        </p>
      </div>

      <div className="container margin-top--lg">
        <div className="row">
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Individuals and home lab users</h4>
              </div>
              <div className="card__body">
                <p>
                  Lightweight and fast. Access your home network securely when
                  on the road.
                </p>
                <ul>
                  <li>Effortless to deploy on any infrastructure</li>
                  <li>Community plan supports unlimited devices</li>
                  <li>Open-source and self-hosted</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Access your personal project &gt;</Link>
              </div>
            </div>
          </div>
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Growing businesses</h4>
              </div>
              <div className="card__body">
                <p>
                  Keep up with increasing network and compliance demands as you
                  scale your team and infrastructure.
                </p>
                <ul>
                  <li>Integrate your identity provider</li>
                  <li>Quickly onboard/offboard employees</li>
                  <li>Segment access for contractors</li>
                  <li>High performance, reduce bottlenecks</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Scale your secure access &gt;</Link>
              </div>
            </div>
          </div>
        </div>
        <div className="row margin-top--md">
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Remote organizations</h4>
              </div>
              <div className="card__body">
                <p>
                  Transitioning to remote? Perfect timing to replace the legacy
                  VPN. Improve your security posture and reduce support tickets.
                </p>
                <ul>
                  <li>Require periodic re-authentication</li>
                  <li>Enforce MFA / 2FA</li>
                  <li>Self-serve user portal</li>
                  <li>Export logs to your observability platform</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Secure your remote workforce &gt;</Link>
              </div>
            </div>
          </div>
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Technical IT teams</h4>
              </div>
              <div className="card__body">
                <p>
                  Firezone runs on your infrastructure. Customize it to suit
                  your needs and architecture.
                </p>
                <ul>
                  <li>Built on WireGuard®</li>
                  <li>No vendor lock-in</li>
                  <li>Supports OIDC and SAML 2.0</li>
                  <li>Flexible and configurable</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Explore the documentation &gt;</Link>
              </div>
            </div>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2 className="hero__title">Join our community</h2>
      </center>
      <p>Stay up to date with product launches and new features.</p>
      <div className="container margin-top--lg">
        <div className="row">
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">30+</h3>
                </center>
              </div>
              <div className="card__body">
                <p>
                  <center>Contributors</center>
                </p>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://github.com/firezone/firezone/graphs/contributors"
                  >
                    Build Firezone
                  </a>
                </center>
              </div>
            </div>
          </div>
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">4,100+</h3>
                </center>
              </div>
              <div className="card__body">
                <p>
                  <center>Github Stars</center>
                </p>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://github.com/firezone/firezone"
                  >
                    Github
                  </a>
                </center>
              </div>
            </div>
          </div>
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">250+</h3>
                </center>
              </div>
              <div className="card__body">
                <p>
                  <center>Members</center>
                </p>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://firezone-users.slack.com/join/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA#/shared-invite/email"
                  >
                    Join Slack
                  </a>
                </center>
              </div>
            </div>
          </div>
        </div>
        <div className="row margin-top--md"></div>
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2>Deploy self-hosted Firezone</h2>
      </center>

      <p>
        Set up secure access and start onboarding users in minutes. Run the
        install script on a supported host to deploy Firezone with Docker. Copy
        the one-liner below to install Firezone in minutes.
      </p>

      <InstallBlock />

      <div className="row margin-top--xl">
        <div className="col col--12">
          <center>
            <a className="button button--primary" href="/docs/deploy">
              Deploy now
            </a>
          </center>
        </div>
      </div>

      {/*
        <div className="col col&#45;&#45;6">
            <center>
                <a className="button button&#45;&#45;primary" href="/1.0/signup">
                Join the 1.0 beta wailist &#45;>
                </a>
            </center>
        </div>
        */}
    </div>
  );
}
