import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Sync with Google Workspace • Firezone Docs",
  description:
    "Automatically synchronize users and groups from Google Workspace to Firezone.",
};

export default function Page() {
  return <Content />;
}
