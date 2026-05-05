import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Policies",
  description:
    "Create Firezone access policies that grant Groups access to Resources. Build least-privileged zero trust controls — see the policies guide.",
};

export default function Page() {
  return <_Page />;
}
