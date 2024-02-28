import HubspotForm from "@/components/HubspotForm";
import Link from "next/link";

export default function EarlyAccessForm() {
  return (
    <div className="pt-8 grid sm:grid-cols-2 gap-8 items-start">
      <div className="px-4 mb-8">
        <h2 className="mb-8 py-4 border-b text-2xl font-bold tracking-tight text-neutral-900 sm:text-4xl ">
          FAQ
        </h2>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg ">
          Why sign up for early access?
        </h3>
        <ul className="md:text-lg mb-6 list-inside list-disc space-y-2">
          <li>Be among the first to try Firezone 1.0</li>
          <li>Accelerate the roadmap with prioritized feedback</li>
          <li>Dedicated Slack channel for onboarding and support</li>
          <li>Free unlimited usage during the beta period</li>
        </ul>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg ">
          What's new in 1.0?
        </h3>
        <p className="md:text-lg mb-6">
          Quite a lot, as it turns out! Here are some of the highlights:
        </p>
        <ul className="md:text-lg mb-6 list-inside list-disc space-y-2">
          <li>Native clients for all major platforms</li>
          <li>A new, snappy SaaS-delivered admin portal</li>
          <li>STUN peer discovery with firewall holepunching</li>
          <li>Group-based access policies built on zero trust principles</li>
          <li>Automated user provisioning for supported IdPs</li>
          <li>Split DNS with configurable upstreams</li>
          <li>All-new REST API</li>
          <li>Automatic failover, load balancing</li>
        </ul>
        <h3 className="mb-4 lg:text-2xl md:text-xl font-bold tracking-tight text-neutral-900 text-lg ">
          What's the pricing model?
        </h3>
        <p className="md:text-lg mb-6">
          See our{" "}
          <Link href="/pricing" className="hover:underline text-accent-500">
            pricing page
          </Link>{" "}
          for details.
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
