import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Use Cases: NAT Gateway",
  description: "Use Firezone to route your team's traffic through a public IP.",
};

export default function Page() {
  return <_Page />;
}
