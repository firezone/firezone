import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Debug Logs • Firezone Docs",
  description:
    "Docker deployments of Firezone generate and store debug logs to a JSON file on the host machine.",
};

export default function Page() {
  return <Content />;
}
