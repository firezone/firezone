import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Groups",
  description:
    "Create Firezone Groups to organize Users for access control. Sync from your identity provider or define them manually — see the guide.",
};

export default function Page() {
  return <Content />;
}
