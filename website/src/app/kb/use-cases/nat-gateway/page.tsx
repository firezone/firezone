import _Page from "./_page";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Use Cases: NAT Gateway • Firezone Docs",
  description: "Use Firezone to route your team's traffic through a public IP.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
