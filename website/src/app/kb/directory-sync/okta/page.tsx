import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Directory Sync Okta • Firezone Docs",
  description:
    "Configure Okta Directory Sync to automatically synchronize users and groups from your Okta tenant to Firezone.",
};

export default function Page() {
  return <Content />;
}
