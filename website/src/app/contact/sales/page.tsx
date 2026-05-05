import SalesLeadForm from "@/components/SalesLeadForm";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Get a Demo — Sales & Pricing",
  description:
    "Request a Firezone demo, discuss enterprise zero trust pricing, and learn how to secure your team. Book a 30-minute call with our sales team today.",
};

export default function Page() {
  return <SalesLeadForm />;
}
