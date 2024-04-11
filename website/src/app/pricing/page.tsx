import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Plans and Pricing • Firezone",
  description:
    "Firezone pricing plans. Choose the right plan for your needs. No credit card required to sign up.",
};

export default function Page() {
  return <_Page />;
}
