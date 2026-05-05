import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Sync with Okta",
  description:
    "Automatically synchronize users and groups from Okta to Firezone.",
};

export default function Page() {
  return <Content />;
}
