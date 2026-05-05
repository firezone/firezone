import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Users",
  description:
    "Create Firezone Users manually or sync from your identity provider. Manage user accounts and access — read the user provisioning guide.",
};

export default function Page() {
  return <Content />;
}
