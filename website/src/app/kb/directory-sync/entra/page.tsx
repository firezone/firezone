import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Sync with Microsoft Entra ID",
  description:
    "Automatically synchronize users and groups from Microsoft Entra ID to Firezone.",
};

export default function Page() {
  return <Content />;
}
