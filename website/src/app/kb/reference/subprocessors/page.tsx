import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Subprocessors",
  description:
    "View the subprocessors Firezone uses to provide and operate the service. Read our compliance and data-handling reference.",
};

export default function Page() {
  return <Content />;
}
