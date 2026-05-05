import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Backup and Restore",
  description:
    "Back up and restore your Firezone deployment. Critical config lives in the Admin portal — learn what to back up and how to recover.",
};

export default function Page() {
  return <Content />;
}
