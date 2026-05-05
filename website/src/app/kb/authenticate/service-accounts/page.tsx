import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Service Accounts",
  description:
    "Create and manage Firezone service accounts for non-human actors. Authenticate scripts and automation with tokens — read the guide.",
};

export default function Page() {
  return <Content />;
}
