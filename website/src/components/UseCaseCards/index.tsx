import Link from "next/link";
import Image from "next/image";
import { HiArrowLongRight } from "react-icons/hi2";
import { Route } from "next";

function CardHeading({ children }: { children: React.ReactNode }) {
  return (
    <h4 className="font-semibold tracking-tight leading-none text-xl mb-3 inline-block">
      {children}
    </h4>
  );
}

function Card({
  narrow,
  children,
}: {
  narrow?: boolean;
  children: React.ReactNode;
}) {
  const container = `
    shadow-lg relative flex justify-center rounded-3xl min-h-[440px] p-8 overflow-hidden
    ${narrow ? "lg:col-span-7 bg-accent-200" : "lg:col-span-9 bg-primary-200"}`;

  return <div className={container}>{children}</div>;
}

function Button({ text, href }: { text: string; href: URL | Route<string> }) {
  return (
    <Link href={href}>
      <button className="group transform transition duration-50 hover:ring-1 hover:ring-neutral-900 inline-flex mt-6 gap-1 items-center bg-neutral-900 rounded-full text-neutral-50 text-sm px-5 py-2.5">
        {text}
        <HiArrowLongRight className="w-5 h-5 group-hover:translate-x-1 group-hover:scale-110 duration-50 transition transform" />
      </button>
    </Link>
  );
}

export default function UseCaseCards() {
  return (
    <section className="py-24">
      <div className="max-w-[1240px] flex flex-col items-center mx-auto">
        <h6 className="uppercase text-sm font-semibold text-primary-450 place-content-center tracking-wide mb-2">
          Use cases
        </h6>
        <h3 className="px-4 mb-8 text-3xl md:text-4xl lg:text-5xl text-center leading-tight tracking-tight font-bold inline-block">
          One product. Endless possibilities.
          <span className="text-primary-450"> Zero </span>hassle.
        </h3>
        <div className="grid lg:grid-cols-16 gap-6 mt-8 mx-2 md:mx-6">
          <Card>
            <div className="text-center md:text-left mt-2 md:mt-4 lg:mt-6">
              <CardHeading>Scale access to cloud resources.</CardHeading>
              <p>
                Eliminate throughput bottlenecks that plague other VPNs.
                Firezone&apo;s load-balancing architecture scales horizontally
                to handle an unlimited number of connections to even the most
                bandwidth-intensive services.
              </p>
              <Button
                text="Scale your security"
                href="/kb/use-cases/scale-vpc-access"
              />
            </div>
            <Image
              className="absolute -bottom-12 sm:-bottom-20 md:-bottom-24 lg:-bottom-16 mx-auto px-4"
              src="/images/resource-list.png"
              width={700}
              height={350}
              alt="Resource List"
            />
          </Card>
          <Card narrow>
            <div className="text-center md:max-w-[420px] text-pretty">
              <Image
                className="mx-auto mb-8"
                src="/images/two-factor-graphic.png"
                width={260}
                height={289}
                alt="Two-Factor Graphic"
              />
              <CardHeading>Add two-factor auth to WireGuard.</CardHeading>
              <p>
                Looking for 2FA for WireGuard? Look no further. Firezone
                integrates with any OIDC-compatible identity provider to
                consistently enforce multi-factor authentication across your
                workforce.
              </p>
              <Button
                text="Connect your identity provider"
                href="/kb/authenticate"
              />
            </div>
          </Card>
          <Card narrow>
            <Image
              className="absolute right-0 max-h-[200px] md:max-h-max w-auto"
              src="/images/manage-access-saas.png"
              width={380}
              height={241}
              alt="Manage access to SaaS graphic"
            />
            <div className="w-full flex items-end">
              <div className="w-full text-center md:text-left">
                <CardHeading>Manage access to a SaaS app</CardHeading>
                <p>
                  Manage access to a third-party SaaS app like HubSpot or
                  GitHub.
                </p>
                <Button
                  text="Configure your app"
                  href="/kb/use-cases/saas-app-access"
                />
              </div>
            </div>
          </Card>
          <Card>
            <div>
              <div className="text-center">
                <Image
                  className="mx-auto mb-8"
                  src="/images/access-onprem-network.png"
                  width={300}
                  height={225}
                  alt="Access on-prem network graphic"
                />
              </div>
              <div className="w-full flex items-end">
                <div className="w-full text-center md:text-left">
                  <CardHeading>Access an on-prem network</CardHeading>
                  <p>
                    Firezone securely punches through firewalls with ease, so
                    keep those ports closed. Connections pick the shortest path
                    and your attack surface is minimized, keeping your most
                    sensitive resources invisible to attackers.
                  </p>
                  <Button
                    text="Set up secure access"
                    href="/kb/use-cases/private-network-access"
                  />
                </div>
              </div>
            </div>
          </Card>
          <Card>
            <div className="w-full mt-2 md:mt-4 lg:mt-6 text-center md:text-left">
              <CardHeading>Block malicious DNS</CardHeading>
              <p>
                {
                  "Use Firezone to improve your team's Internet security by blocking DNS queries to known malicious domains."
                }
              </p>
              <Button text="Secure your DNS" href="/kb/use-cases/secure-dns" />
            </div>
            <Image
              className="absolute bottom-0 px-4"
              src="/images/block-malicious-dns.png"
              width={577}
              height={266}
              alt="Block Malicious DNS"
            />
          </Card>
          <Card narrow>
            <div className="text-center text-pretty">
              <Image
                className="mx-auto mb-8"
                src="/images/access-private-web-app.png"
                width={377}
                height={231}
                alt="Private web app graphic"
              />
              <CardHeading>Access a private web app</CardHeading>
              <p>
                Secure access to a privately hosted web application like GitLab
                or Metabase.
              </p>
              <Button
                text="Secure your web app"
                href="/kb/use-cases/web-app-access"
              />
            </div>
          </Card>
        </div>
      </div>
    </section>
  );
}
