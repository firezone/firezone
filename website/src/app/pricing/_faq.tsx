"use client";

import Link from "next/link";
import {
  Accordion,
  AccordionPanel,
  AccordionTitle,
  AccordionContent,
} from "flowbite-react";

export default function PricingFAQ() {
  return (
    <Accordion>
      <AccordionPanel>
        <AccordionTitle>
          How long does it take to set up Firezone?
        </AccordionTitle>
        <AccordionContent>
          A simple deployment takes{" "}
          <Link
            href="/kb/quickstart"
            className="hover:underline text-accent-500"
          >
            less than 10 minutes{" "}
          </Link>
          and can be accomplished with by installing the{" "}
          <Link
            href="/kb/client-apps"
            className="hover:underline text-accent-500"
          >
            Firezone Client
          </Link>{" "}
          and{" "}
          <Link
            href="/kb/deploy/gateways"
            className="hover:underline text-accent-500"
          >
            deploying one or more Gateways
          </Link>
          .{" "}
          <Link href="/kb" className="hover:underline text-accent-500">
            Visit our docs
          </Link>{" "}
          for more information and step by step instructions.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>Is there a self-hosted plan?</AccordionTitle>
        <AccordionContent>
          All of the source code for the entire Firezone product is available at
          our{" "}
          <Link
            href="https://www.github.com/firezone/firezone"
            className="hover:underline text-accent-500"
          >
            GitHub repository
          </Link>
          {
            ", and you're free to self-host Firezone for your organization without restriction. However, we don't offer documentation or support for self-hosting Firezone at this time."
          }
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          Do I need to rip and replace my current VPN to use Firezone?
        </AccordionTitle>
        <AccordionContent>
          {
            "No. As long they're set up to access different resources, you can run Firezone alongside your existing remote access solutions, and switch over whenever you're ready. There's no need for any downtime or unnecessary disruptions."
          }
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>Can I try Firezone before I buy it?</AccordionTitle>
        <AccordionContent>
          Yes. The Starter plan is free to use without limitation. No credit
          card is required to get started. The Enterprise plan includes a free
          pilot period to evaluate whether Firezone is a good fit for your
          organization.{" "}
          <Link
            href="/contact/sales"
            className="hover:underline text-accent-500"
          >
            Contact sales
          </Link>{" "}
          to request a demo.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          My seat counts have changed. Can I adjust my plan?
        </AccordionTitle>
        <AccordionContent>
          <p>Yes.</p>
          <p className="mt-2">
            {"For the "}
            <strong>Team</strong>
            {
              " plan, you can add or remove seats at any time. When adding seats, you'll be charged a prorated amount for the remainder of the billing cycle. When removing seats, the change will take effect at the end of the billing cycle."
            }
          </p>
          <p className="mt-2">
            {"For the "}
            <strong>Enterprise</strong>
            {
              " plan, contact your account manager to request a seat increase. You'll then be billed for the prorated amount for the remainder of the billing cycle."
            }
          </p>
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          What happens if I increase seats on the Team plan?
        </AccordionTitle>
        <AccordionContent>
          Changes are effective immediately. You will be charged a prorated
          increase that reflects the additional seat count for the remainder of
          the billing cycle.
          <p className="mt-2">
            For example, if you are on a yearly Team plan and at month 6 you add
            5 seats, the prorated charge is <code>5 * 50 * 0.5 = $125</code> and
            is billed when you make the change.
          </p>
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          What happens if I decrease seats on the Team plan?
        </AccordionTitle>
        <AccordionContent>
          Seat decreases are applied only at the end of your current billing
          cycle (monthly or yearly). If you remove 5 seats, those seats remain
          paid through the end of the cycle and can be reassigned to other
          users.
          <p className="mt-2">
            We do not process refunds for seat-count decreases. Instead, the
            removed seats function as account credit until your billing cycle
            renews.
          </p>
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          What happens to my data with Firezone enabled?
        </AccordionTitle>
        <AccordionContent>
          Network traffic is always end-to-end encrypted, and by default, routes
          directly to Gateways running on your infrastructure. In rare
          circumstances, encrypted traffic can pass through our global relay
          network if a direct connection cannot be established. Firezone can
          never decrypt the contents of your traffic.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>How do I cancel or change my plan?</AccordionTitle>
        <AccordionContent>
          For Starter and Team plans, you can downgrade by going to your Account
          settings in your Firezone admin portal. For Enterprise plans, contact
          your account manager for subscription updates. If
          {"you'd like to completely delete your account, "}
          <Link
            href="mailto:support@firezone.dev"
            className="hover:underline text-accent-500"
          >
            contact support
          </Link>
          .
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>When will I be billed?</AccordionTitle>
        <AccordionContent>
          The Team plan is billed monthly on the same day you start service
          until canceled. Enterprise plans are billed annually.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          How does the annual billing discount work on the Team plan?
        </AccordionTitle>
        <AccordionContent>
          The annual discount is already included in the yearly Team price. To
          use annual billing, select annual when upgrading to Team in your
          Firezone admin portal.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>What payment methods are available?</AccordionTitle>
        <AccordionContent>
          The Starter plan is free and does not require a credit card to get
          started. Team and Enterprise plans can be paid via credit card, ACH,
          or wire transfer.
        </AccordionContent>
      </AccordionPanel>
      <AccordionPanel>
        <AccordionTitle>
          Do you offer special pricing for nonprofits and educational
          institutions?
        </AccordionTitle>
        <AccordionContent>
          Yes. Not-for-profit organizations and educational institutions are
          eligible for a 50% discount.{" "}
          <Link
            href="/contact/sales"
            className="hover:underline text-accent-500"
          >
            Contact sales
          </Link>{" "}
          to request the discount.
        </AccordionContent>
      </AccordionPanel>
    </Accordion>
  );
}
