import { Metadata } from "next";
import _Page from "./_page";
import JsonLd from "@/components/JsonLd";
import {
  softwareApplicationSchema,
  SITE_URL,
} from "@/components/JsonLd/schemas";

export const metadata: Metadata = {
  title: "Zero Trust Pricing & Plans",
  description:
    "Compare Firezone zero trust access plans. Starter is free for personal use; Team and Enterprise scale with your organization. No credit card to start.",
};

export default function Page() {
  return (
    <>
      <JsonLd
        data={softwareApplicationSchema({
          name: "Firezone",
          description:
            "Compare Firezone plans: Starter free for personal use, Team for small organizations, and Enterprise for at-scale deployments.",
          url: `${SITE_URL}/pricing`,
          category: "SecurityApplication",
          offers: [
            {
              name: "Starter",
              price: "0",
              priceCurrency: "USD",
              url: `${SITE_URL}/pricing#starter`,
            },
            {
              name: "Team",
              price: "5",
              priceCurrency: "USD",
              url: `${SITE_URL}/pricing#team`,
            },
            // Enterprise is contact-sales — emit the offer without a
            // placeholder price so rich results don't show "$0".
            {
              name: "Enterprise",
              url: `${SITE_URL}/contact/sales`,
            },
          ],
        })}
      />
      <_Page />
    </>
  );
}
