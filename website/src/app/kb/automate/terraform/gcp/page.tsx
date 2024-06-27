import { Metadata } from "next";
import _Page from "./_page";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Deploy Firezone on GCP • Firezone Docs",
  description:
    "Example Terraform configuration to deploy Firezone on Google Cloud Platform.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
