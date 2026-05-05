import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Quickstart",
  description:
    "Get Firezone up and running in minutes. Follow this quickstart to deploy a Gateway, define Resources, and connect your first Client.",
};

export default function Page() {
  return <_Page />;
}
