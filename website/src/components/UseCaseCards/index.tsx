import Link from "next/link";
import Image from "next/image";
import { HiArrowLongRight, HiCheck, HiXMark } from "react-icons/hi2";
import { manrope } from "@/lib/fonts";
import { Route } from "next";

function CardHeading({ children }: { children: React.ReactNode }) {
  return (
    <h4
      className={`font-semibold tracking-tight leading-none text-xl mb-3 inline-block ${manrope.className}`}
    >
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
    relative flex justify-center rounded-3xl min-h-[440px] p-8 overflow-hidden
    ${narrow ? "lg:col-span-7 bg-accent-200" : "lg:col-span-9 bg-primary-200"}`;

  return <div className={container}>{children}</div>;
}

function Button({ text, href }: { text: string; href: Route<string> | URL }) {
  return (
    <Link href={href}>
      <button className="group transform transition duration-50 hover:ring-1 hover:ring-neutral-900 inline-flex mt-6 gap-1 items-center bg-neutral-900 rounded-full text-neutral-50 text-sm px-5 py-2.5">
        {text}
        <HiArrowLongRight className="group-hover:translate-x-1 group-hover:scale-110" />
      </button>
    </Link>
  );
}

export default function UseCaseCards() {
  return (
    <section className="py-16">
      <div className="max-w-[1240px] flex flex-col items-center mx-auto">
        <h3
          className={`mb-4 text-3xl md:text-4xl lg:text-5xl text-center leading-tight tracking-tight font-bold inline-block ${manrope.className}`}
        >
          How our customers are using Firezone
        </h3>
        <div className="grid lg:grid-cols-16 gap-6 mt-8 mx-6">
          <Card>
            <div>
              <CardHeading>Scale access to VPC Resources.</CardHeading>
              <p>
                Firezone's advanced policy engine can be configured to allow
                access only from certain countries, IPs, and timeframes, so you
                can easily demonstrate compliance with internal and external
                security audits.
              </p>
              <Button
                text="Read about Firezone's architecture"
                href="/kb/architecture"
              />
            </div>
            <Image
              className="absolute -bottom-14 sm:-bottom-20 md:-bottom-24 mx-auto px-4"
              src="/images/resource-list.png"
              width={700}
              height={350}
              alt="Resource List"
            />
          </Card>
          <Card narrow>
            <div className="text-center max-w-[420px] text-pretty">
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
              className="absolute right-0"
              src="/images/manage-access-saas.png"
              width={380}
              height={241}
              alt="Manage access to SaaS graphic"
            />
            <div className="absolute left-5 bottom-5">
              <CardHeading>Manage access to a SaaS app</CardHeading>
              <p>Manage access to a SaaS app like HubSpot or GitHub.</p>
              <Button
                text="Connect your identity provider"
                href="/kb/authenticate"
              />
            </div>
          </Card>
          <Card>
            <div>
              <CardHeading>Access an on-prem network</CardHeading>
              <p>
                Firezone's advanced policy engine can be configured to allow
                access only from certain countries, IPs, and timeframes, so you
                can easily demonstrate compliance with internal and external
                security audits.
              </p>
              <Button
                text="Read about Firezone's architecture"
                href="/kb/architecture"
              />
            </div>
            <Image
              className="absolute bottom-0 translate-y-10 mx-auto px-4"
              src="/images/access-onprem-network.png"
              width={297}
              height={178}
              alt="Resource List"
            />
          </Card>
          <Card>
            <div>
              <CardHeading>Scale access to VPC Resources.</CardHeading>
              <p>
                Firezone's advanced policy engine can be configured to allow
                access only from certain countries, IPs, and timeframes, so you
                can easily demonstrate compliance with internal and external
                security audits.
              </p>
              <Button
                text="Read about Firezone's architecture"
                href="/kb/architecture"
              />
            </div>
            <Image
              className="absolute bottom-0 translate-y-10 mx-auto px-4"
              src="/images/resource-list.png"
              width={700}
              height={350}
              alt="Resource List"
            />
          </Card>
          <Card narrow>
            <div className="flex flex-col items-center text-center max-w-[420px] text-pretty">
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
            <Image
              className="absolute top-5 self-center"
              src="/images/two-factor-graphic.png"
              width={260}
              height={289}
              alt="Two-Factor Graphic"
            />
          </Card>
        </div>
      </div>
    </section>
  );
}
