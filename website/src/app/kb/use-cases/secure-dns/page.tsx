import _Page from "./_page";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Use Cases: Secure DNS • Firezone Docs",
  description:
    "Use Firezone to block malicious DNS queries for your organization.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
