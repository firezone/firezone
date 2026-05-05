import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Resources",
  description:
    "Create Firezone Resources — subnets, IP addresses, or DNS names — to define what users can access. See the resource configuration guide.",
};

export default function Page() {
  return <_Page />;
}
