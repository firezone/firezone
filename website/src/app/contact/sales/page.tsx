import SalesLeadForm from "@/components/SalesLeadForm";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Contact Sales • Firezone",
  description:
    "Request a demo, get more pricing details, and learn how Firezone can secure your organization.",
};

export default function Page() {
  return <SalesLeadForm />;
}
