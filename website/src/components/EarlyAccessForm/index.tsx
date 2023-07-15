import HubspotForm from "@/components/HubspotForm";
import Link from "next/link";

export default function EarlyAccessForm() {
  return (
    <div className="pt-8 grid sm:grid-cols-2 gap-8 items-start">
      <div className="px-4 mb-8">
        <h2 className="mb-8 py-4 border-b text-2xl font-bold tracking-tight text-neutral-900 sm:text-4xl dark:text-white">
          FAQ
        </h2>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg dark:text-white">
          Why sign up for early access?
        </h3>
        <ul className="md:text-xl mb-6 list-inside list-disc space-y-2">
          <li>Be among the first to try Firezone 1.0</li>
          <li>Shape the product roadmap with prioritized feedback</li>
          <li>Dedicated Slack channel for onboarding and support</li>
          <li>Free unlimited usage during the beta period</li>
        </ul>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg dark:text-white">
          What's new in 1.0?
        </h3>
        <ul className="md:text-xl mb-6 list-inside list-disc space-y-2">
          <li>Native clients for most major platforms</li>
          <li>A new, snappy SaaS-delivered admin portal</li>
          <li>STUN peer discovery with firewall holepunching</li>
          <li>Group-based access policies built on zero trust principles</li>
          <li>Automated user provisioning for supported IdPs</li>
          <li>Split DNS with configurable upstream provider</li>
          <li>All-new REST API</li>
          {/*
          <li>Automatic failover, load balancing</li>
          */}
        </ul>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg dark:text-white">
          How much will it cost?
        </h3>
        <p className="md:text-xl mb-6">
          We're still working out pricing details for the 1.0 release and will
          launch an updated pricing page when we have more to share. Our goal is
          to price Firezone competitively among other products in the space with
          a cost that scales predictably according to the value it provides.
        </p>
      </div>
      <div className="w-full">
        <HubspotForm
          title="Enter your details to enroll"
          portalId="23723443"
          formId="1a618e17-ef54-4325-bf0e-ed2431cc8cd2"
        />
      </div>
    </div>
  );
}
