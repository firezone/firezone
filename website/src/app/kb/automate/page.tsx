import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Automate",
  description: "Automation recipes for deploying and managing Firezone.",
};

export default function Page() {
  return <_Page />;
}
