import FAQ from "@/components/FAQ";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "FAQ • Firezone Docs",
  description: "Firezone Documentation",
};

export default function Page() {
  return <FAQ />;
}
