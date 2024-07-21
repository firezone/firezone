import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Deploy Firezone on GCP • Firezone Docs",
  description:
    "Example Terraform configuration to deploy Firezone on Google Cloud Platform.",
};

export default function Page() {
  return <_Page />;
}
