import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Directory Sync",
  description:
    "Learn how Firezone directory sync works with Google Workspace, Microsoft Entra, Okta, and JumpCloud. Sync users and groups automatically.",
};

export default function Page() {
  return <Content />;
}
