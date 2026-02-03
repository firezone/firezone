import Link from "next/link";

export default function AboutFirezone() {
  return (
    <div className="bg-neutral-100 border-l-4 border-primary-500 p-6 my-8">
      <h2 className="text-2xl font-bold mb-4">About Firezone</h2>
      <p className="mb-4">
        {
          "Firezone is an open source platform for securely managing remote access to your organization's networks and applications. Unlike traditional VPNs, Firezone takes a granular, least-privileged approach with group-based policies that control access to individual applications, entire subnets, and everything in between. "
        }
        <Link
          href="https://app.firezone.dev/sign_up"
          className="text-accent-500 underline hover:no-underline"
        >
          Get started for free
        </Link>{" "}
        or{" "}
        <Link
          href="/kb"
          className="text-accent-500 underline hover:no-underline"
        >
          learn more
        </Link>{" "}
        about how Firezone can help secure your organization.
      </p>
    </div>
  );
}
