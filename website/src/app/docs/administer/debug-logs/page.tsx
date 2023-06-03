import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Debug Logs",
  description:
    "Docker deployments of Firezone generate and store debug logs to a JSON file on the host machine.",
};

export default function Page() {
  return <Content />;
}
