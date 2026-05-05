import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Deploy",
  description:
    "Deploy Firezone end-to-end: set up Sites, Gateways, Resources, Groups, Users, and Policies. Follow the step-by-step deployment guide.",
};

export default function Page() {
  return <_Page />;
}
