import EarlyAccessForm from "@/components/EarlyAccessForm";
import { Metadata } from "next";

const metadata: Metadata = {
  title: "1.0 Early Access • Firezone",
  description: "Get early access to Firezone 1.0.",
};

export default function EarlyAccess() {
  return <EarlyAccessForm />;
}
