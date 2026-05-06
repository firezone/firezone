import { Metadata } from "next";
import Link from "next/link";
import JsonLd from "@/components/JsonLd";
import {
  softwareApplicationSchema,
  SITE_URL,
} from "@/components/JsonLd/schemas";
import { CustomerLogosColored } from "@/components/CustomerLogos";
import PlanTable from "./plan_table";
import Tiers from "./_tiers";
import FAQ from "./_faq";

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
      <Tiers />
      <section className="py-24 bg-gradient-to-b to-neutral-50 from-white">
        <CustomerLogosColored />
      </section>
      <section className="bg-neutral-50 py-14">
        <div className="mb-14 mx-auto max-w-screen-lg px-3">
          <h2 className="mb-14 justify-center text-4xl font-bold text-neutral-900">
            Compare plans
          </h2>
          <PlanTable />
        </div>
      </section>
      <section className="bg-neutral-100 border-t border-neutral-200 p-14">
        <div className="mx-auto max-w-screen-sm">
          <h2 className="mb-14 justify-center text-4xl font-bold text-neutral-900">
            FAQ
          </h2>
          <FAQ />
        </div>
      </section>
      <section className="bg-neutral-100 border-t border-neutral-200 p-14">
        <div className="mx-auto max-w-screen-xl md:grid md:grid-cols-2">
          <div>
            <h2 className="w-full justify-center mb-8 text-2xl md:text-3xl font-semibold text-neutral-900">
              The WireGuard® solution for Enterprise.
            </h2>
          </div>
          <div className="mb-14 w-full text-center">
            <Link href="/contact/sales">
              <button
                type="button"
                className="w-64 text-white tracking-tight rounded-sm duration-50 hover:ring-2 hover:ring-primary-300 transition transform shadow-lg text-lg px-5 py-2.5 bg-primary-450 font-semibold"
              >
                Request a demo
              </button>
            </Link>
          </div>
        </div>
      </section>
    </>
  );
}
