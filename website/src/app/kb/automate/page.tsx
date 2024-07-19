import { Metadata } from "next";
import _Page from "./_page";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Automate • Firezone Docs",
  description: "Automation recipes for deploying and managing Firezone.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
