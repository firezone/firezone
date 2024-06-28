import { Metadata } from "next";
import _Page from "./_page";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Deploy Firezone on AWS • Firezone Docs",
  description: "Example Terraform configuration to deploy Firezone on AWS.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
