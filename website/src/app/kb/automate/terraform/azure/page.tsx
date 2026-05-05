import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Deploy Firezone on Azure",
  description: "Example Terraform configuration to deploy Firezone on Azure.",
};

export default function Page() {
  return <_Page />;
}
