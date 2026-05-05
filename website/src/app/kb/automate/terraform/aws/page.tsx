import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Deploy Firezone on AWS",
  description: "Example Terraform configuration to deploy Firezone on AWS.",
};

export default function Page() {
  return <_Page />;
}
