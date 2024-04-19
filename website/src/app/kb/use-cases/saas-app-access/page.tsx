import _Page from "./_page";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Use Cases: Public SaaS Access • Firezone Docs",
  description:
    "Use Firezone to secure access to a public SaaS web application.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
