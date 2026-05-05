import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Zero Trust Pricing & Plans",
  description:
    "Compare Firezone zero trust access plans. Starter is free for personal use; Team and Enterprise scale with your organization. No credit card to start.",
};

export default function Page() {
  return <_Page />;
}
